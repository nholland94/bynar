import std.algorithm.iteration;
import std.conv;
import std.file;
import std.math;
import std.range;
import std.stdio;
import std.typecons;

import erupted;

import common;
import input_rel_exp;
import memory;

alias WriteCommandBufferFn = void delegate(VkCommandBuffer, VkPipelineLayout, VkDescriptorSet[]);

enum BufferType {
  STORAGE_BUFFER = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
}

VkDescriptorType descriptorTypeOfBufferType(BufferType t) {
  switch(t) {
  case BufferType.STORAGE_BUFFER:
    return VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
  default:
    throw new Exception("Could not convert descriptor type into buffer type");
  }
}

struct DescriptorSetIndices {
  ulong layoutIndex;
  ulong[] regionIndices;
}

struct ExecutionParameters {
  BufferType[][] layouts;
  MemoryRegion[] regions;
  DescriptorSetIndices[] descriptorSetIndices;
  WriteCommandBufferFn writeCommandBuffer;
}

interface ExecutionStrategy {
  ExecutionParameters getExecutionParameters(ulong inputSize);
}

class Sequential : ExecutionStrategy {
  InputRelExp outputExp;

  this(InputRelExp outputExp) {
    this.outputExp = outputExp;
  }

  ExecutionParameters getExecutionParameters(ulong inputSize) {
    void writeCommandBuffer(VkCommandBuffer commandBuffer, VkPipelineLayout pipelineLayout, VkDescriptorSet[] descriptorSets) {
      vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, [descriptorSets[0]].ptr, 0, null);
      vkCmdDispatch(commandBuffer, (inputSize / uint.sizeof).to!(int), 1, 1);
    }

    ulong outputSize = outputExp.evaluate(inputSize);
    ExecutionParameters parameters = {
      layouts: [
        [ BufferType.STORAGE_BUFFER, BufferType.STORAGE_BUFFER ]
      ],
      regions: [
        MemoryRegion(uint.sizeof, inputSize / uint.sizeof),
        MemoryRegion(uint.sizeof, outputSize / uint.sizeof),
      ],
      descriptorSetIndices: [ { 0, [ 0, 1 ] } ],
      writeCommandBuffer: &writeCommandBuffer
    };

    return parameters;
  }
}

class Reductive : ExecutionStrategy {
  private uint[] calculateBranches(ulong length) {
    FloatingPointControl fpctrl;
    fpctrl.rounding = FloatingPointControl.roundUp;

    ulong lengthLeft = length;
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

    Reductive r = new Reductive();

    assert(equal(r.calculateBranches(256), [128, 64, 32, 16, 8, 4, 2, 1]));
    assert(equal(r.calculateBranches(46), [23, 12, 6, 3, 2, 1]));
    assert(equal(r.calculateBranches(100), [50, 25, 13, 7, 4, 2, 1]));
    assert(equal(r.calculateBranches(61), [31, 16, 8, 4, 2, 1]));
    assert(equal(r.calculateBranches(63), [32, 16, 8, 4, 2, 1]));
  }

  ExecutionParameters getExecutionParameters(ulong inputSize) {
    uint[] branches = calculateBranches(inputSize / uint.sizeof);
    MemoryRegion[] branchRegions = map!((l) => MemoryRegion(uint.sizeof, l))(branches).array;

    void writeCommandBuffer(VkCommandBuffer commandBuffer, VkPipelineLayout pipelineLayout, VkDescriptorSet[] descriptorSets) {
      VkMemoryBarrier memoryBarrier = {
        srcAccessMask: VK_ACCESS_SHADER_WRITE_BIT,
        dstAccessMask: VK_ACCESS_SHADER_READ_BIT,
      };

      foreach(i, branchSize; branches) {
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, [descriptorSets[i]].ptr, 0, null);
        vkCmdDispatch(commandBuffer, branchSize.to!int, 1, 1);

        if(i < branches.length - 1) {
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

    DescriptorSetIndices[] descriptorSetIndices = map!( i => DescriptorSetIndices(0, [ i, i + 1 ]))(iota(branches.length)).array;

    ExecutionParameters parameters = {
      layouts: [
        [ BufferType.STORAGE_BUFFER, BufferType.STORAGE_BUFFER ]
      ],
      regions: [ MemoryRegion(uint.sizeof, inputSize / uint.sizeof) ] ~ branchRegions,
      descriptorSetIndices: descriptorSetIndices,
      writeCommandBuffer: &writeCommandBuffer
    };

    return parameters;
  }
}
