import std.algorithm.iteration;
import std.conv;
import std.file;
import std.math;
import std.range;
import std.stdio;
import std.typecons;

import erupted;

import common;
import int_rel_exp;

// the goal is to eventually remove vulkan dependencies from this interface

/++ Describes available descriptor set bindings and buffers to be bound to them. +/
struct DescriptorSetData {
  uint binding;
  uint layoutIndex;
  VkDescriptorType descriptorType;
  VkDescriptorBufferInfo bufferInfo;
}

enum BufferType {
  STORAGE_BUFFER = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
}

// struct MemoryBlockDescriptor {
//   VkBuffer buffer;
//   ulong size;
// }

struct DescriptorSetIndices {
  ulong layoutIndex;
  ulong bufferIndex;
}

struct PipelineDescriptorInformation {
  BufferType[][] layouts;
  ulong[] blocks;
  DescriptorSetIndices[][][] descriptorSets;
}

interface PipelineConstructorInterface {
  /++ Sets the pipeline constructor input size +/
  void setSize(size_t inputSize, size_t alignment);

  /++ Fetch required buffer size for input and output +/
  size_t inputBufferSize();
  size_t outputBufferSize();

  /++ Fetch shader information +/
  string shaderModuleName();
  string shaderModuleEntryPoint();

  /++ Describe descriptor set bindings and layouts +/
  PipelineDescriptorInformation getDescriptorInformation();
  VkDescriptorSetLayoutBinding[][] descriptorSetLayoutBindings();
  DescriptorSetData[][] descriptorSetDataSets(VkBuffer inputBuffer, VkBuffer outputBuffer);

  /++ Write execution commands to command buffer +/
  void writeCommands(VkCommandBuffer commandBuffer, VkPipelineLayout pipelineLayout, VkDescriptorSet[] descriptorSets);
}

/++ Abstract class for defining pipeline constructors. Implements PipelineConstructorInterface.  +/
abstract class PipelineConstructor : PipelineConstructorInterface {
  private string shaderName;
  private string shaderEntryPoint;
  private IntRelExp outputExp;
  private size_t inputSize;
  private size_t outputSize;

  this(IntRelExp outputExp, string shaderName, string shaderEntryPoint) {
    this.outputExp = outputExp;
    this.shaderName = shaderName;
    this.shaderEntryPoint = shaderEntryPoint;
  }

  void setSize(size_t inputSize, size_t alignment) {
    this.inputSize = alignSize(inputSize, alignment);
    this.outputSize = outputExp.evaluate(inputSize);
  }

  size_t inputBufferSize() { return this.inputSize; }
  size_t outputBufferSize() { return this.outputSize; }
  string shaderModuleName() { return this.shaderName; }
  string shaderModuleEntryPoint() { return this.shaderEntryPoint; }

  abstract PipelineDescriptorInformation getDescriptorInformation();
  abstract VkDescriptorSetLayoutBinding[][] descriptorSetLayoutBindings();
  abstract DescriptorSetData[][] descriptorSetDataSets(VkBuffer inputBuffer, VkBuffer outputBuffer);
  abstract void writeCommands(VkCommandBuffer commandBuffer, VkPipelineLayout pipelineLayout, VkDescriptorSet[] descriptorSets);
}

class SequentialPC : PipelineConstructor {
  // Not sure why this is necessary, but the compiler wants it
  this(IntRelExp outputExp, string shaderName, string shaderEntryPoint) {
    super(outputExp, shaderName, shaderEntryPoint);
  }

  override PipelineDescriptorInformation getDescriptorInformation() {
    PipelineDescriptorInformation info = {
      layouts: [
        [ BufferType.STORAGE_BUFFER, BufferType.STORAGE_BUFFER ]
      ],
      blocks: [
        this.inputBufferSize(),
        this.outputBufferSize()
      ],
      descriptorSets: [ [ [ { 0, 0 }, { 0, 1 } ] ] ]
    };

    return info;
  }

  override VkDescriptorSetLayoutBinding[][] descriptorSetLayoutBindings() {
    VkDescriptorSetLayoutBinding[][] bindings = [
      [
        {
          binding: 0,
          descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
          descriptorCount: 1,
          stageFlags: VK_SHADER_STAGE_COMPUTE_BIT
        },
        {
          binding: 1,
          descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
          descriptorCount: 1,
          stageFlags: VK_SHADER_STAGE_COMPUTE_BIT
        }
      ]
    ];

    return bindings;
  }

  override DescriptorSetData[][] descriptorSetDataSets(VkBuffer inputBuffer, VkBuffer outputBuffer) {
    DescriptorSetData[][] dataSets = [
      [
        {
          binding: 0,
          layoutIndex: 0,
          descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
          bufferInfo: {
            buffer: inputBuffer,
            offset: 0,
            range: VK_WHOLE_SIZE
          }
        },
        {
          binding: 1,
          layoutIndex: 0,
          descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
          bufferInfo: {
            buffer: outputBuffer,
            offset: 0,
            range: VK_WHOLE_SIZE
          }
        }
      ]
    ];

    return dataSets;
  }

  override void writeCommands(VkCommandBuffer commandBuffer, VkPipelineLayout pipelineLayout, VkDescriptorSet[] descriptorSets) {
    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, [descriptorSets[0]].ptr, 0, null);
    vkCmdDispatch(commandBuffer, (this.inputSize / uint.sizeof).to!(int), 1, 1);
  }
}

private uint[] calculateBranches(size_t length) {
  FloatingPointControl fpctrl;
  fpctrl.rounding = FloatingPointControl.roundUp;

  size_t lengthLeft = length;
  uint[] brs;
  size_t halfLength;

  // -- TODO replace this with math equation
  do {
    halfLength = lengthLeft / 2 + lengthLeft % 2;
    brs[++brs.length - 1] = halfLength.to!uint;
    lengthLeft = halfLength;
  } while(lengthLeft > 1);

  return brs;
}

unittest {
  bool equal(uint[] a, uint[] b) {
    if(a.length != b.length)
      return false;

    foreach(i; iota(a.length)) {
      if(a[i] != b[i])
        return false;
    }

    return true;
  }

  assert(equal(calculateBranches(256), [128, 64, 32, 16, 8, 4, 2, 1]));
  assert(equal(calculateBranches(46), [23, 12, 6, 3, 2, 1]));
  assert(equal(calculateBranches(100), [50, 25, 13, 7, 4, 2, 1]));
  assert(equal(calculateBranches(61), [31, 16, 8, 4, 2, 1]));
  assert(equal(calculateBranches(63), [32, 16, 8, 4, 2, 1]));
}

class ReductivePC : PipelineConstructor {
  private Nullable!(uint[]) branches;
  private Nullable!(size_t[]) branchSizes;

  this(string shaderName, string shaderEntryPoint) {
    // TODO: support returning 0 with int rel op
    // IntRelExp outputExp = { bytecode: castFrom!(IntRelOp[]).to!(int[])([IntRelOp.Input]).ptr };
    super(outputExp, shaderName, shaderEntryPoint);
  }

  override void setSize(size_t inputSize, size_t alignment) {
    this.inputSize = alignSize(inputSize, alignment);
    this.outputSize = uint.sizeof;
    this.branches = calculateBranches(inputSize / uint.sizeof);
    this.branchSizes = map!((b) => alignSize(b * uint.sizeof, alignment))(this.branches).array;
  }

  override size_t inputBufferSize() {
    return (this.inputSize + reduce!"a+b"(this.branchSizes));
  }

  override PipelineDescriptorInformation getDescriptorInformation() {
    DescriptorSetIndices[][][] descriptorSetIndices;
    descriptorSetIndices.length = this.branches.length;

    foreach(i; iota(this.branches.length)) {
      DescriptorSetIndices[][] indices = [ [ { 0, i }, { 0, i + 1 } ] ];
      descriptorSetIndices[i] = indices;
    }

    PipelineDescriptorInformation info = {
      layouts: [
        [ BufferType.STORAGE_BUFFER, BufferType.STORAGE_BUFFER ]
      ],
      blocks: this.branchSizes ~ [this.outputBufferSize()],
      descriptorSets: descriptorSetIndices
    };

    return info;
  }

  override VkDescriptorSetLayoutBinding[][] descriptorSetLayoutBindings() {
    VkDescriptorSetLayoutBinding[][] bindings = [
      [
        {
          binding: 0,
          descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
          descriptorCount: 1,
          stageFlags: VK_SHADER_STAGE_COMPUTE_BIT
        },
        {
          binding: 1,
          descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
          descriptorCount: 1,
          stageFlags: VK_SHADER_STAGE_COMPUTE_BIT
        }
      ]
    ];

    return bindings;
  }

  override DescriptorSetData[][] descriptorSetDataSets(VkBuffer inputBuffer, VkBuffer outputBuffer) {
    DescriptorSetData[][] dataSets;
    dataSets.length = this.branches.length;

    uint lastInputSize = (this.inputSize + this.inputSize % 2).to!uint;
    uint inputOffset = 0;

    foreach(i, branchSize; this.branchSizes[0..$-1]) {
      DescriptorSetData[] dataSet = [
        {
          binding: 0,
          layoutIndex: 0,
          descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
          bufferInfo: {
            buffer: inputBuffer,
            offset: inputOffset,
            range: VK_WHOLE_SIZE
          }
        },
        {
          binding: 1,
          layoutIndex: 0,
          descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
          bufferInfo: {
            buffer: inputBuffer,
            offset: inputOffset + lastInputSize,
            range: VK_WHOLE_SIZE
          }
        }
      ];

      dataSets[i] = dataSet;
      inputOffset += lastInputSize;
      lastInputSize = branchSize.to!uint;
    }

    DescriptorSetData[] dataSet = [
      {
        binding: 0,
        layoutIndex: 0,
        descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        bufferInfo: {
          buffer: inputBuffer,
          offset: inputOffset,
          range: VK_WHOLE_SIZE
        }
      },
      {
        binding: 1,
        layoutIndex: 0,
        descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        bufferInfo: {
          buffer: outputBuffer,
          offset: 0,
          range: VK_WHOLE_SIZE
        }
      }
    ];

    dataSets[$-1] = dataSet;

    return dataSets;
  }

  override void writeCommands(VkCommandBuffer commandBuffer, VkPipelineLayout pipelineLayout, VkDescriptorSet[] descriptorSets) {
    VkMemoryBarrier memoryBarrier = {
      srcAccessMask: VK_ACCESS_SHADER_WRITE_BIT,
      dstAccessMask: VK_ACCESS_SHADER_READ_BIT,
    };

    foreach(i, branchSize; this.branches) {
      vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, [descriptorSets[i]].ptr, 0, null);
      vkCmdDispatch(commandBuffer, branchSize.to!int, 1, 1);

      if(i < this.branches.length - 1) {
        vkCmdPipelineBarrier(
            commandBuffer,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1, [memoryBarrier].ptr,
            0, null,
            0, null
        );
      }
    }
  }
}
