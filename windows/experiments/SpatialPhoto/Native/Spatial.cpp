#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <array>
#include <vector>
#include <string>
#include <stdexcept>
#include <algorithm>
#include <cstring>
#include <cmath>
#include <DirectXMath.h>

using Microsoft::WRL::ComPtr;
namespace {
thread_local std::wstring lastError;
void check(HRESULT hr) {
    if (FAILED(hr)) { char message[64]; sprintf_s(message, "Direct3D error 0x%08X", static_cast<unsigned>(hr)); throw std::runtime_error(message); }
}
const char* shader = R"hlsl(
Texture2D<float4> photo : register(t0);
Texture2D<float> depth : register(t1);
SamplerState linearClamp : register(s0);
cbuffer Settings : register(b0) { float shift; float margin; float invertDepth; float unused; };
struct Vertex { float4 position : SV_POSITION; float2 uv : TEXCOORD; };
Vertex VS(uint id : SV_VertexID) {
    Vertex v; float2 p = float2((id << 1) & 2, id & 2);
    v.position = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1); v.uv = p; return v;
}
float readDepth(float2 uv) { float d = depth.SampleLevel(linearClamp, uv, 0); return invertDepth > 0 ? 1 - d : d; }
float4 PS(Vertex v) : SV_TARGET {
    float2 base = (v.uv - 0.5) * (1 - 2 * margin) + 0.5;
    uint w, h; depth.GetDimensions(w, h); float2 texel = 1.0 / float2(w, h);
    float center = readDepth(base);
    float edge = max(abs(readDepth(base + float2(texel.x, 0)) - center), abs(readDepth(base - float2(texel.x, 0)) - center));
    float safeShift = shift * (1 - smoothstep(0.03, 0.15, edge));
    float2 source = base;
    [unroll] for (int i = 0; i < 4; i++) source = base + float2(safeShift * (readDepth(source) - 0.5), 0);
    float residual = abs(source.x - base.x - safeShift * (readDepth(source) - 0.5));
    source = lerp(source, base, smoothstep(0.001, 0.004, residual));
    return photo.SampleLevel(linearClamp, saturate(source), 0);
}
)hlsl";

const char* portraitShader = R"hlsl(
Texture2D<float4> background : register(t0);
Texture2D<float4> sourcePhoto : register(t2);
Texture2D<float> sourceDepth : register(t3);
SamplerState linearClamp : register(s0);
SamplerState pointClamp : register(s1);
cbuffer Camera : register(b0) { row_major float4x4 transform; float textured; float sourceWeight; float projectionX; float projectionY; };
struct Input { float3 position : POSITION; float3 color : COLOR; float2 uv : TEXCOORD; };
struct Vertex { float4 position : SV_POSITION; float3 color : COLOR; float2 uv : TEXCOORD; float3 world : TEXCOORD1; };
Vertex VS(Input input) { Vertex v; v.position = mul(float4(input.position, 1), transform); v.color = input.color; v.uv = input.uv; v.world = input.position; return v; }
float4 PS(Vertex v) : SV_TARGET {
    // Derivatives are evaluated before branching so projection blends remain defined at silhouettes.
    float3 normal = normalize(cross(ddx(v.world), ddy(v.world)));
    if (textured > 0.5) return float4(background.SampleLevel(linearClamp, v.uv, 0).rgb, 1);
    float3 color = v.color;
    if (sourceWeight > 0 && v.world.z > 0.05) {
        float2 uv = float2(0.5 + v.world.x * projectionX / v.world.z, 0.5 - v.world.y * projectionY / v.world.z);
        float4 photo = sourcePhoto.SampleLevel(linearClamp, uv, 0);
        float z = sourceDepth.SampleLevel(pointClamp, uv, 0);
        // Match the source camera's near/far planes (0.05, 100), then compare in world units.
        float visibleDepth = 5.0 / (100.0 - z * 99.95);
        float visible = v.world.z <= visibleDepth + 0.004 ? 1 : 0;
        float facing = abs(dot(normal, normalize(-v.world)));
        float inFrame = all(uv >= 0) && all(uv <= 1) ? 1 : 0;
        float blend = sourceWeight * photo.a * visible * inFrame * smoothstep(0.12, 0.4, facing);
        color = lerp(color, photo.rgb, blend);
    }
    return float4(color, 1);
}
)hlsl";

D3D12_HEAP_PROPERTIES heap(D3D12_HEAP_TYPE type) { D3D12_HEAP_PROPERTIES p{}; p.Type = type; p.CreationNodeMask = p.VisibleNodeMask = 1; return p; }
D3D12_RESOURCE_DESC buffer(UINT64 size) {
    D3D12_RESOURCE_DESC d{}; d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; d.Width = size;
    d.Height = 1; d.DepthOrArraySize = d.MipLevels = 1; d.SampleDesc.Count = 1; d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; return d;
}
D3D12_RESOURCE_DESC texture(UINT w, UINT h, DXGI_FORMAT format, D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE) {
    D3D12_RESOURCE_DESC d{}; d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; d.Width = w; d.Height = h;
    d.DepthOrArraySize = d.MipLevels = 1; d.Format = format; d.SampleDesc.Count = 1; d.Flags = flags; return d;
}
void transition(ID3D12GraphicsCommandList* list, ID3D12Resource* resource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER b{}; b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition = { resource, D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, before, after }; list->ResourceBarrier(1, &b);
}
struct Renderer {
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Fence> fence;
    ComPtr<IDXGISwapChain3> swap;
    ComPtr<ID3D12DescriptorHeap> rtvs, srvs;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pipeline;
    ComPtr<ID3D12RootSignature> portraitRoot;
    ComPtr<ID3D12PipelineState> portraitPipeline;
    ComPtr<ID3D12PipelineState> portraitSourcePipeline;
    ComPtr<ID3D12Resource> portraitPhoto, portraitSourceDepth;
    bool hasPortraitPhoto = false;
    struct PortraitConstants { DirectX::XMFLOAT4X4 matrix; float textured, sourceWeight, projectionX, projectionY; };
    ComPtr<ID3D12Resource> portraitVertices, portraitIndices, portraitDepth;
    ComPtr<ID3D12DescriptorHeap> portraitDsv;
    D3D12_VERTEX_BUFFER_VIEW portraitVertexView{};
    D3D12_INDEX_BUFFER_VIEW portraitIndexView{};
    UINT portraitIndexCount = 0;
    float portraitFov = 40, portraitPivot = 3;
    std::array<ComPtr<ID3D12Resource>, 2> targets, images;
    HANDLE eventHandle = nullptr;
    UINT64 fenceValue = 0;
    UINT width = 1, height = 1, imageWidth = 1, imageHeight = 1, rtvStep = 0;
    bool ready = false;
    std::wstring adapterName;
    ~Renderer() { if (queue && fence && eventHandle) { try { wait(); } catch (...) {} } if (eventHandle) CloseHandle(eventHandle); }
    void wait() {
        const auto value = ++fenceValue; check(queue->Signal(fence.Get(), value));
        if (fence->GetCompletedValue() < value) {
            check(fence->SetEventOnCompletion(value, eventHandle));
            if (WaitForSingleObject(eventHandle, 30000) != WAIT_OBJECT_0) throw std::runtime_error("GPU fence timeout");
        }
    }
    void begin() { check(allocator->Reset()); check(commands->Reset(allocator.Get(), nullptr)); }
    void submit() { check(commands->Close()); ID3D12CommandList* lists[] = { commands.Get() }; queue->ExecuteCommandLists(1, lists); wait(); }
    void initialize(HWND hwnd, UINT w, UINT h, bool warp) {
        ComPtr<IDXGIFactory6> factory; check(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)));
        ComPtr<IDXGIAdapter1> adapter;
        if (warp) { check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter))); check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device))); }
        else {
            for (UINT index = 0; factory->EnumAdapterByGpuPreference(index, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&adapter)) != DXGI_ERROR_NOT_FOUND; ++index) {
                DXGI_ADAPTER_DESC1 desc{}; adapter->GetDesc1(&desc);
                if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) && SUCCEEDED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)))) break;
                adapter.Reset();
            }
            if (!device) throw std::runtime_error("No hardware Direct3D 12 adapter");
        }
        DXGI_ADAPTER_DESC1 desc{}; check(adapter->GetDesc1(&desc)); adapterName = desc.Description;
        D3D12_COMMAND_QUEUE_DESC q{}; q.Type = D3D12_COMMAND_LIST_TYPE_DIRECT; check(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue)));
        check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
        check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&commands))); check(commands->Close());
        check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)));
        eventHandle = CreateEventW(nullptr, FALSE, FALSE, nullptr); if (!eventHandle) check(HRESULT_FROM_WIN32(GetLastError()));
        D3D12_DESCRIPTOR_HEAP_DESC hd{}; hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors = 2;
        check(device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&rtvs))); rtvStep = device->GetDescriptorHandleIncrementSize(hd.Type);
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; hd.NumDescriptors = 4; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        check(device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&srvs)));
        if (hwnd) {
            DXGI_SWAP_CHAIN_DESC1 sd{}; sd.Width = w; sd.Height = h; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 2; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
            ComPtr<IDXGISwapChain1> initial; check(factory->CreateSwapChainForHwnd(queue.Get(), hwnd, &sd, nullptr, nullptr, &initial)); check(initial.As(&swap));
            factory->MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER);
        }
        resize(w, h);
        D3D12_DESCRIPTOR_RANGE range{}; range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV; range.NumDescriptors = 2;
        D3D12_ROOT_PARAMETER params[2]{}; params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[0].DescriptorTable = { 1, &range }; params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS; params[1].Constants = { 0, 0, 4 }; params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_STATIC_SAMPLER_DESC sampler{}; sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS; sampler.MaxLOD = D3D12_FLOAT32_MAX; sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC rd{}; rd.NumParameters = 2; rd.pParameters = params; rd.NumStaticSamplers = 1; rd.pStaticSamplers = &sampler;
        ComPtr<ID3DBlob> blob, errors; check(D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors));
        check(device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), IID_PPV_ARGS(&root)));
        ComPtr<ID3DBlob> vs, ps;
        for (const auto& entry : { std::pair{ "VS", "vs_5_0" }, std::pair{ "PS", "ps_5_0" } }) {
            ComPtr<ID3DBlob> compiled;
            const HRESULT hr = D3DCompile(shader, strlen(shader), "Spatial", nullptr, nullptr, entry.first, entry.second, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &compiled, &errors);
            if (FAILED(hr) && errors) throw std::runtime_error(static_cast<const char*>(errors->GetBufferPointer())); check(hr);
            if (entry.first[0] == 'V') vs = compiled; else ps = compiled;
        }
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{}; pd.pRootSignature = root.Get();
        pd.VS = { vs->GetBufferPointer(), vs->GetBufferSize() }; pd.PS = { ps->GetBufferPointer(), ps->GetBufferSize() };
        pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        pd.SampleMask = UINT_MAX; pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        pd.RasterizerState.DepthClipEnable = TRUE; pd.DepthStencilState.DepthEnable = FALSE; pd.DepthStencilState.StencilEnable = FALSE;
        pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE; pd.NumRenderTargets = 1; pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM; pd.SampleDesc.Count = 1;
        check(device->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pipeline)));
    }
    void resize(UINT w, UINT h) {
        if (!w || !h || w > 8192 || h > 8192) throw std::runtime_error("Invalid render size");
        wait(); for (auto& target : targets) target.Reset(); width = w; height = h;
        if (swap) check(swap->ResizeBuffers(2, w, h, DXGI_FORMAT_R8G8B8A8_UNORM, 0));
        auto handle = rtvs->GetCPUDescriptorHandleForHeapStart();
        for (UINT i = 0; i < (swap ? 2u : 1u); i++) {
            if (swap) check(swap->GetBuffer(i, IID_PPV_ARGS(&targets[i])));
            else {
                const auto hp = heap(D3D12_HEAP_TYPE_DEFAULT); const auto td = texture(w, h, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
                check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&targets[i])));
            }
            device->CreateRenderTargetView(targets[i].Get(), nullptr, handle); handle.ptr += rtvStep;
        }
        if (portraitDsv) createPortraitDepth();
    }
    void createPortraitDepth() {
        portraitDepth.Reset();
        const auto hp = heap(D3D12_HEAP_TYPE_DEFAULT);
        const auto td = texture(width, height, DXGI_FORMAT_D32_FLOAT, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
        D3D12_CLEAR_VALUE clear{}; clear.Format = DXGI_FORMAT_D32_FLOAT; clear.DepthStencil.Depth = 1;
        check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_DEPTH_WRITE, &clear, IID_PPV_ARGS(&portraitDepth)));
        device->CreateDepthStencilView(portraitDepth.Get(), nullptr, portraitDsv->GetCPUDescriptorHandleForHeapStart());
    }
    void initializePortrait() {
        if (portraitPipeline) return;
        D3D12_DESCRIPTOR_HEAP_DESC heapDesc{}; heapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV; heapDesc.NumDescriptors = 2;
        check(device->CreateDescriptorHeap(&heapDesc, IID_PPV_ARGS(&portraitDsv))); createPortraitDepth();
        D3D12_DESCRIPTOR_RANGE range{}; range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV; range.NumDescriptors = 4;
        D3D12_ROOT_PARAMETER params[2]{}; params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[0].DescriptorTable = { 1, &range }; params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS; params[1].Constants = { 0, 0, 20 }; params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        D3D12_STATIC_SAMPLER_DESC sampler{}; sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS; sampler.MaxLOD = D3D12_FLOAT32_MAX; sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_STATIC_SAMPLER_DESC samplers[]{ sampler, sampler }; samplers[1].ShaderRegister = 1; samplers[1].Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
        D3D12_ROOT_SIGNATURE_DESC rd{}; rd.NumParameters = 2; rd.pParameters = params; rd.NumStaticSamplers = 2; rd.pStaticSamplers = samplers;
        rd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        ComPtr<ID3DBlob> blob, errors; check(D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors));
        check(device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), IID_PPV_ARGS(&portraitRoot)));
        ComPtr<ID3DBlob> vs, ps;
        check(D3DCompile(portraitShader, strlen(portraitShader), "Portrait", nullptr, nullptr, "VS", "vs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &vs, &errors));
        check(D3DCompile(portraitShader, strlen(portraitShader), "Portrait", nullptr, nullptr, "PS", "ps_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &ps, &errors));
        D3D12_INPUT_ELEMENT_DESC input[] = {
            { "POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
            { "COLOR", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
            { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 24, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 }
        };
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{}; pd.pRootSignature = portraitRoot.Get();
        pd.VS = { vs->GetBufferPointer(), vs->GetBufferSize() }; pd.PS = { ps->GetBufferPointer(), ps->GetBufferSize() };
        pd.InputLayout = { input, 3 }; pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        pd.SampleMask = UINT_MAX; pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE; pd.RasterizerState.DepthClipEnable = TRUE;
        pd.DepthStencilState.DepthEnable = TRUE; pd.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL; pd.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS_EQUAL;
        pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE; pd.NumRenderTargets = 1; pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM; pd.DSVFormat = DXGI_FORMAT_D32_FLOAT; pd.SampleDesc.Count = 1;
        check(device->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&portraitPipeline)));
        // The original camera's person-only depth pass prevents projecting the face/arms onto hidden surfaces.
        pd.PS = {}; pd.NumRenderTargets = 0; pd.RTVFormats[0] = DXGI_FORMAT_UNKNOWN;
        check(device->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&portraitSourcePipeline)));
    }
    ComPtr<ID3D12Resource> uploadBuffer(const void* data, UINT bytes) {
        ComPtr<ID3D12Resource> result; const auto hp = heap(D3D12_HEAP_TYPE_UPLOAD); const auto desc = buffer(bytes);
        check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&result)));
        void* mapped; const D3D12_RANGE empty{ 0, 0 }; check(result->Map(0, &empty, &mapped)); memcpy(mapped, data, bytes); result->Unmap(0, nullptr); return result;
    }
    void setPortrait(const float* vertices, UINT vertexCount, const UINT* indices, UINT indexCount, UINT frameWidth, UINT frameHeight, float fov, float pivot) {
        if (!ready || !vertices || !indices || vertexCount < 7 || vertexCount > 1000000 || indexCount < 9 || indexCount > 6000000 || indexCount % 3
            || !frameWidth || !frameHeight || frameWidth > 4096 || frameHeight > 4096 || !std::isfinite(fov) || fov < 10 || fov > 90 || !std::isfinite(pivot) || pivot <= .1f)
            throw std::runtime_error("Invalid portrait scene");
        for (UINT i = 0; i < vertexCount * 8; ++i) if (!std::isfinite(vertices[i])) throw std::runtime_error("Non-finite portrait vertex");
        for (UINT i = 0; i < indexCount; ++i) if (indices[i] >= vertexCount) throw std::runtime_error("Portrait index out of bounds");
        wait(); initializePortrait();
        portraitVertices = uploadBuffer(vertices, vertexCount * 32); portraitIndices = uploadBuffer(indices, indexCount * 4);
        portraitVertexView = { portraitVertices->GetGPUVirtualAddress(), vertexCount * 32, 32 };
        portraitIndexView = { portraitIndices->GetGPUVirtualAddress(), indexCount * 4, DXGI_FORMAT_R32_UINT };
        portraitIndexCount = indexCount; imageWidth = frameWidth; imageHeight = frameHeight; portraitFov = fov; portraitPivot = pivot;
    }
    void setPortraitPhoto(const unsigned char* rgba, UINT w, UINT h) {
        if (!portraitPipeline) throw std::runtime_error("No portrait geometry for source photo");
        if (rgba && (!w || !h || w != imageWidth || h != imageHeight)) throw std::runtime_error("Source photo dimensions do not match scene camera");
        wait(); hasPortraitPhoto = false; portraitPhoto.Reset(); portraitSourceDepth.Reset();
        auto srv = srvs->GetCPUDescriptorHandleForHeapStart();
        const UINT srvStep = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        srv.ptr += static_cast<SIZE_T>(srvStep) * 2;
        D3D12_SHADER_RESOURCE_VIEW_DESC sv{}; sv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; sv.Texture2D.MipLevels = 1;
        if (!rgba) {
            sv.Format = DXGI_FORMAT_R8G8B8A8_UNORM; device->CreateShaderResourceView(nullptr, &sv, srv); srv.ptr += srvStep;
            sv.Format = DXGI_FORMAT_R32_FLOAT; device->CreateShaderResourceView(nullptr, &sv, srv); return;
        }
        auto hp = heap(D3D12_HEAP_TYPE_DEFAULT); const auto photoDesc = texture(w, h, DXGI_FORMAT_R8G8B8A8_UNORM);
        check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &photoDesc, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&portraitPhoto)));
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{}; UINT64 total;
        device->GetCopyableFootprints(&photoDesc, 0, 1, 0, &footprint, nullptr, nullptr, &total);
        ComPtr<ID3D12Resource> upload; hp = heap(D3D12_HEAP_TYPE_UPLOAD); const auto uploadDesc = buffer(total);
        check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &uploadDesc, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&upload)));
        unsigned char* mapped; const D3D12_RANGE empty{ 0, 0 }; check(upload->Map(0, &empty, reinterpret_cast<void**>(&mapped)));
        for (UINT y = 0; y < h; ++y) memcpy(mapped + footprint.Offset + static_cast<size_t>(y) * footprint.Footprint.RowPitch, rgba + static_cast<size_t>(y) * w * 4, static_cast<size_t>(w) * 4);
        upload->Unmap(0, nullptr);
        sv.Format = photoDesc.Format; device->CreateShaderResourceView(portraitPhoto.Get(), &sv, srv); srv.ptr += srvStep;
        hp = heap(D3D12_HEAP_TYPE_DEFAULT); const auto depthDesc = texture(w, h, DXGI_FORMAT_R32_TYPELESS, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
        D3D12_CLEAR_VALUE clear{}; clear.Format = DXGI_FORMAT_D32_FLOAT; clear.DepthStencil.Depth = 1;
        check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &depthDesc, D3D12_RESOURCE_STATE_DEPTH_WRITE, &clear, IID_PPV_ARGS(&portraitSourceDepth)));
        auto dsv = portraitDsv->GetCPUDescriptorHandleForHeapStart(); dsv.ptr += device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
        D3D12_DEPTH_STENCIL_VIEW_DESC dv{}; dv.Format = DXGI_FORMAT_D32_FLOAT; dv.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2D;
        device->CreateDepthStencilView(portraitSourceDepth.Get(), &dv, dsv);
        sv.Format = DXGI_FORMAT_R32_FLOAT; device->CreateShaderResourceView(portraitSourceDepth.Get(), &sv, srv);
        begin();
        D3D12_TEXTURE_COPY_LOCATION src{}; src.pResource = upload.Get(); src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; src.PlacedFootprint = footprint;
        D3D12_TEXTURE_COPY_LOCATION dst{}; dst.pResource = portraitPhoto.Get(); dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        commands->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
        transition(commands.Get(), portraitPhoto.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        commands->ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, 1, 0, 0, nullptr); commands->OMSetRenderTargets(0, nullptr, FALSE, &dsv);
        D3D12_VIEWPORT viewport{ 0, 0, static_cast<float>(w), static_cast<float>(h), 0, 1 }; D3D12_RECT rect{ 0, 0, static_cast<LONG>(w), static_cast<LONG>(h) };
        commands->RSSetViewports(1, &viewport); commands->RSSetScissorRects(1, &rect);
        commands->SetPipelineState(portraitSourcePipeline.Get()); commands->SetGraphicsRootSignature(portraitRoot.Get());
        ID3D12DescriptorHeap* heaps[]{ srvs.Get() }; commands->SetDescriptorHeaps(1, heaps); commands->SetGraphicsRootDescriptorTable(0, srvs->GetGPUDescriptorHandleForHeapStart());
        PortraitConstants constants{};
        DirectX::XMStoreFloat4x4(&constants.matrix, DirectX::XMMatrixPerspectiveFovLH(DirectX::XMConvertToRadians(portraitFov), static_cast<float>(w) / h, .05f, 100.0f));
        commands->SetGraphicsRoot32BitConstants(1, 20, &constants, 0);
        commands->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST); commands->IASetVertexBuffers(0, 1, &portraitVertexView); commands->IASetIndexBuffer(&portraitIndexView);
        commands->DrawIndexedInstanced(portraitIndexCount - 6, 1, 6, 0, 0);
        transition(commands.Get(), portraitSourceDepth.Get(), D3D12_RESOURCE_STATE_DEPTH_WRITE, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE); submit();
        hasPortraitPhoto = true;
    }
    void renderPortrait(float degrees, bool usePhoto = true) {
        if (!portraitPipeline || !portraitIndexCount || !std::isfinite(degrees)) throw std::runtime_error("No portrait 3D scene");
        using namespace DirectX;
        const float radians = XMConvertToRadians(std::clamp(degrees, -60.0f, 60.0f));
        const auto eye = XMVectorSet(portraitPivot * sinf(radians), 0, portraitPivot * (1 - cosf(radians)), 1);
        const auto target = XMVectorSet(0, 0, portraitPivot, 1);
        const auto view = XMMatrixLookAtLH(eye, target, XMVectorSet(0, 1, 0, 0));
        const auto projection = XMMatrixPerspectiveFovLH(XMConvertToRadians(portraitFov), static_cast<float>(imageWidth) / imageHeight, .05f, 100.0f);
        PortraitConstants constants{};
        constants.sourceWeight = hasPortraitPhoto && usePhoto ? 1.0f : 0.0f;
        constants.projectionY = .5f / tanf(XMConvertToRadians(portraitFov) * .5f);
        constants.projectionX = constants.projectionY * imageHeight / imageWidth;
        XMStoreFloat4x4(&constants.matrix, view * projection);
        const UINT index = swap ? swap->GetCurrentBackBufferIndex() : 0;
        begin(); transition(commands.Get(), targets[index].Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
        auto rtv = rtvs->GetCPUDescriptorHandleForHeapStart(); rtv.ptr += static_cast<SIZE_T>(index) * rtvStep;
        const auto dsv = portraitDsv->GetCPUDescriptorHandleForHeapStart();
        const float background[]{ .035f, .043f, .055f, 1 }; commands->ClearRenderTargetView(rtv, background, 0, nullptr);
        commands->ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, 1, 0, 0, nullptr); commands->OMSetRenderTargets(1, &rtv, FALSE, &dsv);
        const float scale = std::min(static_cast<float>(width) / imageWidth, static_cast<float>(height) / imageHeight);
        const float vw = imageWidth * scale, vh = imageHeight * scale;
        D3D12_VIEWPORT vp{ (width - vw) / 2, (height - vh) / 2, vw, vh, 0, 1 }; D3D12_RECT rect{ 0, 0, static_cast<LONG>(width), static_cast<LONG>(height) };
        commands->RSSetViewports(1, &vp); commands->RSSetScissorRects(1, &rect);
        commands->SetPipelineState(portraitPipeline.Get()); commands->SetGraphicsRootSignature(portraitRoot.Get());
        ID3D12DescriptorHeap* heaps[]{ srvs.Get() }; commands->SetDescriptorHeaps(1, heaps); commands->SetGraphicsRootDescriptorTable(0, srvs->GetGPUDescriptorHandleForHeapStart());
        commands->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST); commands->IASetVertexBuffers(0, 1, &portraitVertexView); commands->IASetIndexBuffer(&portraitIndexView);
        constants.textured = 1; commands->SetGraphicsRoot32BitConstants(1, 20, &constants, 0); commands->DrawIndexedInstanced(6, 1, 0, 0, 0);
        constants.textured = 0; commands->SetGraphicsRoot32BitConstants(1, 20, &constants, 0); commands->DrawIndexedInstanced(portraitIndexCount - 6, 1, 6, 0, 0);
        transition(commands.Get(), targets[index].Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON); submit(); if (swap) check(swap->Present(1, 0));
    }
    void setImages(const unsigned char* rgba, UINT w, UINT h, const unsigned char* depthData, UINT dw, UINT dh) {
        if (!rgba || !depthData || !w || !h || !dw || !dh || std::max({ w, h, dw, dh }) > 4096) throw std::runtime_error("Invalid texture size");
        ready = false; wait(); begin();
        std::array<ComPtr<ID3D12Resource>, 2> upload;
        auto srv = srvs->GetCPUDescriptorHandleForHeapStart(); const UINT step = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        for (UINT i = 0; i < 2; ++i) {
            const UINT iw = i ? dw : w, ih = i ? dh : h, channels = i ? 1 : 4;
            const auto td = texture(iw, ih, i ? DXGI_FORMAT_R8_UNORM : DXGI_FORMAT_R8G8B8A8_UNORM);
            auto hp = heap(D3D12_HEAP_TYPE_DEFAULT);
            check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&images[i])));
            D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{}; UINT64 total; device->GetCopyableFootprints(&td, 0, 1, 0, &footprint, nullptr, nullptr, &total);
            hp = heap(D3D12_HEAP_TYPE_UPLOAD); const auto bd = buffer(total);
            check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&upload[i])));
            unsigned char* mapped; D3D12_RANGE empty{ 0, 0 }; check(upload[i]->Map(0, &empty, reinterpret_cast<void**>(&mapped)));
            const auto source = i ? depthData : rgba;
            for (UINT y = 0; y < ih; ++y) memcpy(mapped + footprint.Offset + static_cast<size_t>(y) * footprint.Footprint.RowPitch, source + static_cast<size_t>(y) * iw * channels, static_cast<size_t>(iw) * channels);
            upload[i]->Unmap(0, nullptr);
            D3D12_TEXTURE_COPY_LOCATION src{}; src.pResource = upload[i].Get(); src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; src.PlacedFootprint = footprint;
            D3D12_TEXTURE_COPY_LOCATION dst{}; dst.pResource = images[i].Get(); dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            commands->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr); transition(commands.Get(), images[i].Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            D3D12_SHADER_RESOURCE_VIEW_DESC sv{}; sv.Format = td.Format; sv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; sv.Texture2D.MipLevels = 1;
            device->CreateShaderResourceView(images[i].Get(), &sv, srv); srv.ptr += step;
        }
        submit(); imageWidth = w; imageHeight = h; ready = true;
    }
    void render(float position, float amplitude, bool invert) {
        if (!ready || !std::isfinite(position) || !std::isfinite(amplitude)) throw std::runtime_error("No valid image pair");
        const UINT index = swap ? swap->GetCurrentBackBufferIndex() : 0;
        begin(); transition(commands.Get(), targets[index].Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_RENDER_TARGET);
        auto target = rtvs->GetCPUDescriptorHandleForHeapStart(); target.ptr += static_cast<SIZE_T>(index) * rtvStep;
        const float background[]{ .035f, .043f, .055f, 1 }; commands->ClearRenderTargetView(target, background, 0, nullptr); commands->OMSetRenderTargets(1, &target, FALSE, nullptr);
        const float scale = std::min(static_cast<float>(width) / imageWidth, static_cast<float>(height) / imageHeight);
        const float vw = imageWidth * scale, vh = imageHeight * scale;
        D3D12_VIEWPORT vp{ (width - vw) / 2, (height - vh) / 2, vw, vh, 0, 1 }; D3D12_RECT scissor{ 0, 0, static_cast<LONG>(width), static_cast<LONG>(height) };
        commands->RSSetViewports(1, &vp); commands->RSSetScissorRects(1, &scissor); commands->SetPipelineState(pipeline.Get()); commands->SetGraphicsRootSignature(root.Get());
        ID3D12DescriptorHeap* heaps[]{ srvs.Get() }; commands->SetDescriptorHeaps(1, heaps); commands->SetGraphicsRootDescriptorTable(0, srvs->GetGPUDescriptorHandleForHeapStart());
        // Relative depth is centered at 0.5, so half the displacement coefficient
        // reserves the full border travel. Keep the crop fixed throughout a pass.
        const float a = std::clamp(amplitude, 0.0f, .24f); const float constants[]{ std::clamp(position, -1.0f, 1.0f) * a, a * .5f, invert ? 1.0f : 0.0f, 0 };
        commands->SetGraphicsRoot32BitConstants(1, 4, constants, 0); commands->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST); commands->DrawInstanced(3, 1, 0, 0);
        transition(commands.Get(), targets[index].Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COMMON); submit();
        if (swap) check(swap->Present(1, 0));
    }
    void readback(unsigned char* destination, UINT length) {
        if (swap || !destination || length < static_cast<UINT64>(width) * height * 4) throw std::runtime_error("Readback requires offscreen target and full buffer");
        const auto td = targets[0]->GetDesc(); D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{}; UINT64 total;
        device->GetCopyableFootprints(&td, 0, 1, 0, &fp, nullptr, nullptr, &total);
        ComPtr<ID3D12Resource> read; const auto hp = heap(D3D12_HEAP_TYPE_READBACK); const auto bd = buffer(total);
        check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&read)));
        begin(); transition(commands.Get(), targets[0].Get(), D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION dst{}; dst.pResource = read.Get(); dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; dst.PlacedFootprint = fp;
        D3D12_TEXTURE_COPY_LOCATION src{}; src.pResource = targets[0].Get(); src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        commands->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr); transition(commands.Get(), targets[0].Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_COMMON); submit();
        unsigned char* mapped; D3D12_RANGE range{ 0, static_cast<SIZE_T>(total) }; check(read->Map(0, &range, reinterpret_cast<void**>(&mapped)));
        for (UINT y = 0; y < height; ++y) memcpy(destination + static_cast<size_t>(y) * width * 4, mapped + fp.Offset + static_cast<size_t>(y) * fp.Footprint.RowPitch, static_cast<size_t>(width) * 4);
        D3D12_RANGE empty{ 0, 0 }; read->Unmap(0, &empty);
    }
};
template<class Action> int protect(Action action) {
    try { action(); lastError.clear(); return 0; }
    catch (const std::exception& e) { const std::string s = e.what(); lastError.assign(s.begin(), s.end()); return -1; }
    catch (...) { lastError = L"Unknown native failure"; return -1; }
}
}
#define API extern "C" __declspec(dllexport)
API const wchar_t* SpatialLastError() { return lastError.c_str(); }
API void* SpatialCreate(HWND hwnd, UINT w, UINT h, int warp) {
    Renderer* renderer = nullptr;
    const int result = protect([&] { renderer = new Renderer(); renderer->initialize(hwnd, w, h, warp != 0); });
    if (result) { delete renderer; return nullptr; } return renderer;
}
API const wchar_t* SpatialAdapter(Renderer* r) { return r ? r->adapterName.c_str() : L""; }
API int SpatialSetImages(Renderer* r, const unsigned char* photo, UINT w, UINT h, const unsigned char* depth, UINT dw, UINT dh) { return protect([&] { r->setImages(photo, w, h, depth, dw, dh); }); }
API int SpatialRender(Renderer* r, float position, float amplitude, int invert) { return protect([&] { r->render(position, amplitude, invert != 0); }); }
API int SpatialSetPortrait(Renderer* r, const float* vertices, UINT vertexCount, const UINT* indices, UINT indexCount, UINT width, UINT height, float fov, float pivot) { return protect([&] { r->setPortrait(vertices, vertexCount, indices, indexCount, width, height, fov, pivot); }); }
API int SpatialRenderPortrait(Renderer* r, float degrees) { return protect([&] { r->renderPortrait(degrees); }); }
API int SpatialRenderPortraitTexture(Renderer* r, float degrees, int usePhoto) { return protect([&] { r->renderPortrait(degrees, usePhoto != 0); }); }
API int SpatialSetPortraitPhoto(Renderer* r, const unsigned char* rgba, UINT w, UINT h) { return protect([&] { r->setPortraitPhoto(rgba, w, h); }); }
API int SpatialResize(Renderer* r, UINT w, UINT h) { return protect([&] { r->resize(w, h); }); }
API int SpatialReadback(Renderer* r, unsigned char* data, UINT length) { return protect([&] { r->readback(data, length); }); }
API void SpatialDestroy(Renderer* r) { delete r; }
