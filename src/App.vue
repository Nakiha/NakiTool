<template>
  <div ref="div_drop" class="dropzone" @drop.prevent="onDrop">
    <canvas ref="canvas_main"></canvas>
    <div> test </div>
  </div>
</template>

<script setup lang="ts">
import fs from "fs";
import { onMounted, ref, watch } from "vue";
import yuvShader from "./shaders/yuv.wgsl?raw"

const isInited = ref(false)
watch(isInited, (newVal, oldVal) => {
  console.log(`isInited changed from ${oldVal} to ${newVal}`)
})

const gpuDocCtx = ref<{
  device: GPUDevice;
  adapter: GPUAdapter;
  canvasCtx: GPUCanvasContext;
} | null>(null)
let div_drop = ref<HTMLDivElement | null>(null)
let canvas_main = ref<HTMLCanvasElement | null>(null)

interface ImageDataWithMeta {
  buffer: Buffer;
  width: number;
  height: number;
  // 可以继续扩展其他元数据，比如 format、timestamp 等
  format?: string;
}
let image = ref<ImageDataWithMeta | null>(null)
watch(image, (newVal, oldVal) => {
  // 暂时不考虑async函数运行过程中重入
  if (newVal == null) {
    console.log("image is null")
    return
  }
  let image = newVal as ImageDataWithMeta;
  (async () => {
    const {device, adapter, canvasCtx} = gpuDocCtx.value!
    const gpuCtx = canvas_main.value!.getContext("webgpu") as GPUCanvasContext
    const presetationFormat = navigator.gpu.getPreferredCanvasFormat()
    gpuCtx.configure({
      device: device,
      format: presetationFormat,
    })

    // TODO: use index buffer to remove 2 lapped vertex
    // prepare vetex data & write into buffer
    const vertexData = new Float32Array([
      // 2byte position 2byte texcoord
      // position y is -1.0 to 1.0
      // texcoord y is 1.0 to 0.0
      // 1st triangle
      -1.0, -1.0, 0.0, 1.0,
      1.0, -1.0, 1.0, 1.0,
      -1.0, 1.0, 0.0, 0.0,
      // 2st triangle
      -1.0, 1.0, 0.0, 0.0,
      1.0, -1.0, 1.0, 1.0, // lapped
      1.0, 1.0, 1.0, 0.0,  // lapped
    ])

    const vertexNum = vertexData.length / 4
    const vertexBuffer = device.createBuffer({
      label: 'vertex buffer',
      size: vertexData.byteLength,
      usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    })
    device.queue.writeBuffer(vertexBuffer, 0, vertexData)

    const module = device.createShaderModule({
      label: 'yuv raw image shader',
      code: yuvShader,
    })

    const pipeline = await device.createRenderPipelineAsync({
      label: 'yuv raw image pipeline',
      layout: 'auto',
      vertex: {
        entryPoint: 'vs',
        module: module,
        buffers: [
          {
            arrayStride: 2*4 + 2*4, // 2 floats position, 2 floats texcoord
            attributes: [
              {shaderLocation: 0, offset: 0, format: 'float32x2'}, // position
              {shaderLocation: 1, offset: 8, format: 'float32x2'}, // texcoord
            ]
          },
        ]
      },
      fragment: {
        entryPoint: 'fs',
        module: module,
        targets: [{ format: presetationFormat,},],
      },
    })

    function CreateGrayTexture(lable: string, width: number, height: number) {
      return device.createTexture({
        label: lable,
        size: [width, height],
        format: 'r8unorm',
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
      })
    }

    function CreateUniformBuffer(label: string, size: number) {
      return device.createBuffer({
        label: label,
        size: size,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      })
    }

    const uniformBufSize =
      2 * 4 + // scale
      2 * 4   // offset
    const uniformBuffer = CreateUniformBuffer("uniform_buffer", uniformBufSize)
    const uniformValues = new Float32Array([
      1.0, 1.0, // scale
      0.0, 0.0, // offset
    ])
    device.queue.writeBuffer(uniformBuffer, 0, uniformValues)

    const texY = CreateGrayTexture("tex_y", image.width, image.height)
    const texU = CreateGrayTexture("tex_u", image.width / 2, image.height / 2)
    const texV = CreateGrayTexture("tex_v", image.width / 2, image.height / 2)
    // TODO: 后续使用计算着色器下采样
    const sampler = device.createSampler({
      label: 'linear sampler',
      magFilter: 'linear',
      minFilter: 'linear',
      mipmapFilter: 'nearest',
      addressModeU: 'clamp-to-edge',
      addressModeV: 'clamp-to-edge',
    })

    {
      function WriteGrayTexture(tex: GPUTexture, buffer: Buffer, width: number, height: number) {
        device.queue.writeTexture(
          { texture: tex }, buffer,
          { bytesPerRow: width, rowsPerImage: height },
          [width, height, 1]
        )
      }
      const sizeY = image.width * image.height
      const sizeU = (image.width / 2) * (image.height / 2)

      console.log("image res:", image.width, "x", image.height , ", image size: ", image.buffer.length, ", y size: ", sizeY, ", u size: ", sizeU)
      WriteGrayTexture(texY, image.buffer.subarray(0, sizeY), image.width, image.height)
      WriteGrayTexture(texU, image.buffer.subarray(sizeY, sizeY + sizeU), image.width / 2, image.height / 2)
      WriteGrayTexture(texV, image.buffer.subarray(sizeY + sizeU), image.width / 2, image.height / 2)
    }

    const bindGroup = device.createBindGroup({
      label: 'bind group',
      layout: pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: uniformBuffer, }, },
        { binding: 1, resource: sampler, },
        { binding: 2, resource: texY.createView(), },
        { binding: 3, resource: texU.createView(), },
        { binding: 4, resource: texV.createView(), },
      ],
    })

    function render() {
      const commandEncoder = device.createCommandEncoder({
        label: 'command encoder',
      })

      const renderPassDesc: GPURenderPassDescriptor = {
        colorAttachments: [
          {
            view: gpuCtx.getCurrentTexture().createView(),
            clearValue: { r: 0.3, g: 0.3, b: 0.3, a: 1 },
            loadOp: 'clear',
            storeOp: 'store',
          },
        ],
      }

      const pass = commandEncoder.beginRenderPass(renderPassDesc)
      pass.setPipeline(pipeline)
      pass.setBindGroup(0, bindGroup)
      pass.setVertexBuffer(0, vertexBuffer)
      pass.draw(vertexNum, 1, 0, 0)
      pass.end()

      device.queue.submit([commandEncoder.finish()])
    }

    render()

    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const canvas = <HTMLCanvasElement>entry.target
        const width = entry.contentBoxSize[0].inlineSize
        const height = entry.contentBoxSize[0].blockSize
        canvas.width = Math.max(1, Math.min(width, device.limits.maxTextureDimension2D))
        canvas.height = Math.max(1, Math.min(height, device.limits.maxTextureDimension2D))
        render()
      }
    })

    observer.observe(canvas_main.value!)
  })()

})

// 避免浏览器显示默认的拖拽效果
document.addEventListener('dragover', (e) => {
  e.preventDefault()
})


const onDrop = (e: DragEvent) => {
  if (isInited.value == false) {
    alert("WebGPU not initialized")
    return
  }

  e.stopPropagation()
  let promises : Promise<Buffer>[] = []
  // 目前只支持拖拽一个文件
  const files = Array.from(e.dataTransfer!.files).slice(0, 1)
  files.map((file) => window.api.getFilePath1(file)).forEach(path => {
    console.log(`file path: ${path}`)
    promises.push(fs.promises.readFile(path))
  })
  Promise.all(promises).then((buffers) => {
    image.value = {
      buffer: buffers[0],
      width: 850,
      height: buffers[0].length / 850 / 1.5, // yuv420p
      format: "yuv420p",
    }
  })
}

onMounted(() => {
  try {
    initWebGpu()
  } catch (e) {
    console.error(e)
    fail("WebGPU not supported")
  }
})

function fail(msg: string) {
  alert(msg)
}

function start() {

}

async function initWebGpu() {
  const gpu = navigator.gpu as GPU
  if (!gpu) throw new Error("WebGPU not supported")

  const adapter = await gpu.requestAdapter()
  if (!adapter) throw new Error("No GPU adapter found")

  const device = await adapter.requestDevice()
  if (!device) throw new Error("No GPU device found")

  device.lost.then((info) => {
    console.log(`Device lost: ${info.message}`)
  })

  gpuDocCtx.value = {
    device,
    adapter,
    canvasCtx: canvas_main.value!.getContext("webgpu") as GPUCanvasContext,
  }

  isInited.value = true

}




</script>

<style scoped>
.dropzone {
  height: 100vh; /* 或100%（前提是父元素有高度） */
  box-sizing: border-box;
  display: flex;
  flex-direction: column; /* 竖直排列 */
  align-items: stretch;
  justify-content: stretch;
}
.dropzone canvas {
  flex: 1 1 auto;
  width: 100%;
  height: 0; /* 让flex控制高度 */
  min-height: 0;
  background: lightblue;
  image-rendering: pixelated;
  image-rendering: crisp-edges;
  display: block;
}
.dropzone > div {
  /* 可选：去掉默认margin */
  margin: 0;
}
</style>
