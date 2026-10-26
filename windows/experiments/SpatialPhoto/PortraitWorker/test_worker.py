import importlib.util
import math
import sys
from pathlib import Path
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("portrait_worker", Path(__file__).with_name("worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class BackgroundCoverage(unittest.TestCase):
    def test_background_contains_frustum_corners_throughout_sixty_degree_sweep(self):
        for width, height in [(400, 600), (600, 600), (1200, 600)]:
            fov = min(40, math.degrees(2 * math.atan(math.tan(math.radians(25)) / (width / height))))
            bounds = worker.background_bounds(width, height, fov, 3, 6)
            xmin, xmax, ymin, ymax = bounds
            self.assertLess(xmin, 0)
            self.assertGreater(xmax, 0)
            self.assertTrue(all(math.isfinite(v) for v in bounds))
            for angle in [-60, -30, 0, 30, 60]:
                s, c = math.sin(math.radians(angle)), math.cos(math.radians(angle))
                t = math.tan(math.radians(fov) / 2)
                for x in [-t * width / height, t * width / height]:
                    distance = (6 - 3 * (1 - c)) / (s * x + c)
                    world_x = 3 * s + (c * x - s) * distance
                    self.assertGreaterEqual(world_x, xmin - 1e-6)
                    self.assertLessEqual(world_x, xmax + 1e-6)
                    self.assertGreaterEqual(-t * distance, ymin - 1e-6)
                    self.assertLessEqual(t * distance, ymax + 1e-6)

    def test_rejects_camera_rays_parallel_to_or_behind_background(self):
        with self.assertRaises(ValueError):
            worker.background_bounds(2000, 400, 60, 3, 6)


if __name__ == "__main__":
    unittest.main()
