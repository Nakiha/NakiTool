struct Vertex {
  @location(0) position: vec2f,
  @location(1) texcoord: vec2f,
}

struct VSOutput {
  @builtin(position) position: vec4f,
  @location(0) texcoord: vec2f,
}

struct Extra {
  scale: vec2f,
  offset: vec2f,
}

@group(0) @binding(0) var<uniform> extra: Extra;

const YUV2RGB = mat4x4f(
  1.1643828125, 0, 1.59602734375, -.87078515625,
  1.1643828125, -.39176171875, -.81296875, .52959375,
  1.1643828125, 2.017234375, 0, -1.081390625,
  0, 0, 0, 1
);

@vertex fn vs(
  vert: Vertex,
) -> VSOutput {
  var vsOut: VSOutput;
  vsOut.position = vec4f(vert.position * extra.scale + extra.offset, 0.0, 1.0);
  vsOut.texcoord = vert.texcoord;
  return vsOut;
}

@group(0) @binding(1) var texSampler: sampler;
@group(0) @binding(2) var texY: texture_2d<f32>;
@group(0) @binding(3) var texU: texture_2d<f32>;
@group(0) @binding(4) var texV: texture_2d<f32>;

@fragment fn fs(fsInput: VSOutput) -> @location(0) vec4f {
  let y = textureSample(texY, texSampler, fsInput.texcoord).r;
  let u = textureSample(texU, texSampler, fsInput.texcoord).r;
  let v = textureSample(texV, texSampler, fsInput.texcoord).r;
  return vec4f(y, u, v, 1.0) * YUV2RGB;
}
