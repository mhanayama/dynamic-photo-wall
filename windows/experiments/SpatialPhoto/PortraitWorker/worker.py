"""Portrait alpha preprocessing. Separate CPU worker; no GUI or network inference.

TripoSR (MIT) is loaded from the pinned, locally installed upstream source.
The CPU marching-cubes adapter uses scikit-image instead of its CUDA extension.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys
import time
import types

VERSION = "portrait-birefnet-lama-triposr-cpu-mc128-v1"


def progress(stage, message):
    print(json.dumps({"stage": stage, "message": message}, ensure_ascii=False), flush=True)


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(4 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def background_bounds(width, height, fov, pivot, depth, maximum_angle=60):
    """Intersect all frustum-corner rays with the background plane over the sweep."""
    tangent = math.tan(math.radians(fov) / 2)
    aspect = width / height
    xs, ys = [], []
    for step in range(-maximum_angle, maximum_angle + 1):
        angle = math.radians(step)
        s, c = math.sin(angle), math.cos(angle)
        eye_x, eye_z = pivot * s, pivot * (1 - c)
        for x in (-aspect * tangent, aspect * tangent):
            ray_x, ray_z = c * x - s, s * x + c
            if ray_z <= 0.02:
                raise ValueError("背景を覆えない画角・カメラ範囲です。")
            distance = (depth - eye_z) / ray_z
            xs.append(eye_x + ray_x * distance)
            ys.extend([-tangent * distance, tangent * distance])
    return min(xs), max(xs), min(ys), max(ys)


def run(args):
    import numpy as np
    import onnxruntime as ort
    from PIL import Image, ImageOps, ImageFilter
    from scipy.ndimage import binary_dilation

    runtime = Path(args.runtime).resolve()
    config = json.loads((runtime / "runtime.json").read_text(encoding="utf-8-sig"))
    models = Path(config["models"])
    lock = json.loads((Path(__file__).parent / "models.json").read_text())
    source_hash = sha(args.input)
    key = hashlib.sha256((source_hash + VERSION + sha(__file__) + str(args.resolution) + json.dumps(lock, sort_keys=True)).encode()).hexdigest()
    output = Path(args.output).resolve() / key
    output.mkdir(parents=True, exist_ok=True)
    manifest_path = output / "manifest.json"
    if manifest_path.exists() and not args.force:
        try:
            manifest = json.loads(manifest_path.read_text())
            if all(sha(output / name) == digest for name, digest in manifest["hashes"].items()):
                progress("complete", str(manifest_path))
                return
        except (OSError, ValueError, KeyError):
            pass
    start = time.perf_counter()
    progress("validate", "モデルを確認しています。初回の人物3D生成は数分かかる場合があります。")
    for entry in lock["files"]:
        if "sha256" in entry and sha(models / entry["path"]) != entry["sha256"]:
            raise ValueError("モデルのSHA256が不一致です: " + entry["path"])
    with Image.open(args.input) as opened:
        if opened.width * opened.height > 64_000_000:
            raise ValueError("6400万画素以下の画像を使用してください。")
        image = ImageOps.exif_transpose(opened).convert("RGB")
    image.thumbnail((1024, 1024), Image.Resampling.LANCZOS)
    width, height = image.size
    image.save(output / "source.png")
    session_options = ort.SessionOptions()
    session_options.intra_op_num_threads = min(8, os.cpu_count() or 4)
    session_options.inter_op_num_threads = 1
    progress("matting", "人物と背景を分離しています。")
    session = ort.InferenceSession(str(models / "birefnet/model.onnx"), session_options, providers=["CPUExecutionProvider"])
    inp = np.asarray(image.resize((1024, 1024), Image.Resampling.BILINEAR), dtype=np.float32) / 255
    inp = (inp - np.array([.485, .456, .406], dtype=np.float32)) / np.array([.229, .224, .225], dtype=np.float32)
    prediction = session.run(None, {session.get_inputs()[0].name: inp.transpose(2, 0, 1)[None]})[-1].squeeze()
    # The upstream export returns logits. Apply sigmoid before alpha matting.
    if not np.isfinite(prediction).all():
        raise ValueError("人物マスクの出力が不正です。")
    if prediction.min() < 0 or prediction.max() > 1:
        prediction = 1 / (1 + np.exp(-np.clip(prediction, -80, 80)))
    matte_image = Image.fromarray(np.uint8(np.clip(prediction, 0, 1) * 255)).resize(image.size, Image.Resampling.BILINEAR)
    alpha = np.asarray(matte_image)
    region = alpha > 127
    ys, xs = np.where(region)
    if len(xs) < width * height * .005:
        raise ValueError("人物を抽出できませんでした。人物が大きく写った画像を使用してください。")
    if len(xs) > width * height * .97:
        raise ValueError("人物マスクが画像全体を覆っています。背景が写った画像を使用してください。")
    bbox = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)
    foreground = image.copy().convert("RGBA")
    foreground.putalpha(matte_image)
    foreground.save(output / "person.png")
    matte_image.save(output / "mask.png")
    del session

    progress("background", "人物の跡と、カメラ移動で見える背景を補完しています。")
    # World coordinates use x right, y up, z forward. Only the background is a plane.
    fov = min(40.0, math.degrees(2 * math.atan(math.tan(math.radians(25)) / (width / height))))
    pivot, bg_depth = 3.0, 6.0
    xmin, xmax, ymin, ymax = background_bounds(width, height, fov, pivot, bg_depth)
    focal = height / (2 * math.tan(math.radians(fov) / 2))
    original_half_w = width * bg_depth / (2 * focal)
    original_half_h = height * bg_depth / (2 * focal)
    # Inpaint on a bounded canvas; paste untouched source pixels back afterward.
    ratio = min(1536 / (xmax - xmin), 1536 / (ymax - ymin), focal / bg_depth)
    canvas_w, canvas_h = max(64, round((xmax - xmin) * ratio)), max(64, round((ymax - ymin) * ratio))
    inner_w, inner_h = max(1, round(2 * original_half_w * ratio)), max(1, round(2 * original_half_h * ratio))
    left, top = round((-original_half_w - xmin) * ratio), round((ymax - original_half_h) * ratio)
    rgb = np.zeros((canvas_h, canvas_w, 3), dtype=np.uint8)
    known = np.zeros((canvas_h, canvas_w), dtype=bool)
    patch = np.asarray(image.resize((inner_w, inner_h), Image.Resampling.LANCZOS))
    expanded_mask = binary_dilation(region, iterations=max(3, round(max(width, height) * .008)))
    patch_mask = np.asarray(Image.fromarray(np.uint8(expanded_mask) * 255).resize((inner_w, inner_h), Image.Resampling.NEAREST)) > 0
    rgb[top:top + inner_h, left:left + inner_w] = patch
    known[top:top + inner_h, left:left + inner_w] = ~patch_mask
    # Edge extension provides context in very large outpaint areas, while the model
    # still receives those areas as holes. It is not represented as true background.
    rgb = np.pad(patch, ((top, canvas_h - top - inner_h), (left, canvas_w - left - inner_w), (0, 0)), mode="edge")
    mask = ~known
    lama = ort.InferenceSession(str(models / "lama/model.onnx"), session_options, providers=["CPUExecutionProvider"])
    small_rgb = np.asarray(Image.fromarray(rgb).resize((512, 512), Image.Resampling.BILINEAR), dtype=np.float32) / 255
    small_mask = np.asarray(Image.fromarray(np.uint8(mask) * 255).resize((512, 512), Image.Resampling.NEAREST), dtype=np.float32) / 255
    feed = {}
    for name in [item.name for item in lama.get_inputs()]:
        feed[name] = small_mask[None, None] if "mask" in name.lower() else small_rgb.transpose(2, 0, 1)[None]
    filled = lama.run(None, feed)[0].squeeze()
    if filled.shape[0] == 3:
        filled = filled.transpose(1, 2, 0)
    if filled.max() <= 1.5:
        filled = filled * 255
    background = np.asarray(Image.fromarray(np.uint8(np.clip(filled, 0, 255))).resize((canvas_w, canvas_h), Image.Resampling.BICUBIC)).copy()
    background[known] = rgb[known]
    Image.fromarray(background).save(output / "background.png")
    del lama

    progress("person3d", "人物の側面を含む3D形状をCPUで生成しています。")
    import torch
    from skimage.measure import marching_cubes
    torch.set_num_threads(min(8, os.cpu_count() or 4))
    sys.path.insert(0, config["source"])
    # Replace only the optional marching-cubes extension with a real CPU extractor.
    # No synthetic geometry or depth extrusion is substituted for model inference.
    mc = types.ModuleType("torchmcubes")
    def cpu_mc(density, threshold):
        vertices, faces, _, _ = marching_cubes(density.detach().cpu().numpy(), level=float(threshold))
        return torch.from_numpy(vertices[:, [2, 1, 0]].copy()), torch.from_numpy(faces.astype(np.int64).copy())
    mc.marching_cubes = cpu_mc
    sys.modules["torchmcubes"] = mc
    # Upstream needs only the DINO architecture JSON, never an extra weight download.
    import tsr.models.tokenizers.image as tokenizer_module
    tokenizer_module.hf_hub_download = lambda **kwargs: str(models / "triposr/dino-config.json")
    from tsr.system import TSR
    from omegaconf import OmegaConf
    model_config = OmegaConf.load(models / "triposr/config.yaml")
    OmegaConf.resolve(model_config)
    model = TSR(model_config)
    state = torch.load(models / "triposr/model.ckpt", map_location="cpu", weights_only=True)
    model.load_state_dict(state)
    model.eval()
    model.renderer.set_chunk_size(8192)
    crop = foreground.crop(bbox)
    extent = max(crop.size)
    square = Image.new("RGBA", (round(extent / .85), round(extent / .85)), (128, 128, 128, 255))
    square.alpha_composite(crop, ((square.width - crop.width) // 2, (square.height - crop.height) // 2))
    with torch.no_grad():
        codes = model(square.convert("RGB"), device="cpu")
        mesh = model.extract_mesh(codes, has_vertex_color=True, resolution=args.resolution)[0]
    if len(mesh.vertices) < 100 or not np.isfinite(mesh.vertices).all():
        raise ValueError("有効な人物3Dメッシュを生成できませんでした。")
    mesh.export(output / "person.glb")
    # TripoSR front camera is on +X with Z up. Convert to the native scene axes.
    source_vertices = np.asarray(mesh.vertices, dtype=np.float32)
    vertices = np.stack([source_vertices[:, 1], source_vertices[:, 2], -source_vertices[:, 0]], axis=1)
    span = float(np.ptp(vertices[:, 1]))
    if span < 1e-5:
        raise ValueError("人物3Dの高さが不正です。")
    target_height = (bbox[3] - bbox[1]) * pivot / focal
    scale = target_height / span
    center = (vertices.min(axis=0) + vertices.max(axis=0)) * .5
    target_center = np.array([((bbox[0] + bbox[2]) / 2 - width / 2) * pivot / focal,
                              (height / 2 - (bbox[1] + bbox[3]) / 2) * pivot / focal, pivot], dtype=np.float32)
    vertices = (vertices - center) * scale + target_center
    colors = np.asarray(mesh.visual.vertex_colors[:, :3], dtype=np.float32) / 255
    packed = np.concatenate([vertices, colors, np.zeros((len(vertices), 2), dtype=np.float32)], axis=1).astype("<f4")
    faces = np.asarray(mesh.faces, dtype="<u4").reshape(-1)
    with open(output / "person.mesh", "wb") as f:
        f.write(struct.pack("<8sII", b"DPWMESH1", len(vertices), len(faces)))
        f.write(packed.tobytes())
        f.write(faces.tobytes())
    if sha(args.input) != source_hash:
        raise ValueError("処理中に元画像が変更されました。再試行してください。")
    files = ["source.png", "person.png", "mask.png", "background.png", "person.glb", "person.mesh"]
    manifest = {"version": VERSION, "sourceHash": source_hash, "width": width, "height": height,
                "fovY": fov, "pivot": pivot, "backgroundDepth": bg_depth,
                "backgroundBounds": [xmin, xmax, ymin, ymax], "maximumAngle": 60,
                "bbox": bbox, "vertexCount": len(vertices), "triangleCount": len(faces) // 3,
                "seconds": time.perf_counter() - start, "generator": "TripoSR CPU; generic object model, identity unverified",
                "hashes": {name: sha(output / name) for name in files}}
    temp = manifest_path.with_suffix(".tmp")
    temp.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    temp.replace(manifest_path)
    progress("complete", str(manifest_path))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--resolution", type=int, choices=[96, 128, 192, 256], default=128)
    parser.add_argument("--force", action="store_true")
    try:
        run(parser.parse_args())
    except Exception as error:
        progress("error", str(error))
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
