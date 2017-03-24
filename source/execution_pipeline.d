import std.algorithm.iteration;
import std.array;
import std.conv;
import std.range;
import std.typecons;
import std.stdio;

import erupted;

import collections;
import common;
import descriptor_set_pool;
import descriptor_set_writer;
import device;
import execution_strategies;
import memory;

struct ExecutionModule {
  string name;
  uint[] shaderCode;
}

struct ExecutionStage {
  ulong shaderModuleIndex;
  string entryPoint;
  ExecutionStrategy strategy;
}

private VkShaderModule createShaderModule(VkDevice device, uint[] shaderCode) {
  VkShaderModuleCreateInfo moduleInfo = {
    codeSize: shaderCode.length * uint.sizeof,
    pCode: shaderCode.ptr
  };

  VkShaderModule shaderModule;
  enforceVk(vkCreateShaderModule(device, &moduleInfo, null, &shaderModule));

  return shaderModule;
}

private VkDescriptorSetLayoutBinding[] processLayoutBindings(BufferType[] bindingTypes) {
  VkDescriptorSetLayoutBinding[] bindings;
  bindings.length = bindingTypes.length;

  foreach(i, bindingType; bindingTypes) {
    VkDescriptorType dsType = descriptorTypeOfBufferType(bindingType);

    VkDescriptorSetLayoutBinding binding = {
      binding: i.to!uint,
      descriptorType: dsType,
      descriptorCount: 1,
      stageFlags: VK_SHADER_STAGE_COMPUTE_BIT
    };

    bindings[i] = binding;
  }

  return bindings;
}

// -- Abstracts array used for descriptor type reference counting
// this abstraction requires some assumptions about the VkDescriptorType
// enum and thus, may need to be changed for future version of Vulkan
private class DescriptorTypeCounter {
  uint[] counts; 

  this() {
    counts.length = VkDescriptorType.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT + 1;
  }

  void add(VkDescriptorType t) {
    counts[castFrom!VkDescriptorType.to!ulong(t)]++;
  }
}

private struct ExecutionStagesAnalysis {
  // count of descriptor sets
  ulong descriptorSetCount;
  // counts of required descriptor types
  DescriptorTypeCounter descriptorTypeCounter;
  // vector of functions to execute when building the command buffer
  WriteCommandBufferFn[] writeCommandBufferFns;
  // memory regions by buffers
  MemoryRegion[][] bufferRegions;
  // pipeline layout by stage
  VkPipelineLayout[] pipelineLayouts;
  // pipeline info by stage
  VkComputePipelineCreateInfo[] pipelineInfos;
  // descriptor set layout handles by descriptor set by stage
  VkDescriptorSetLayout[][] descriptorSetLayouts;
  // region index by descriptor binding by descriptor set by stage
  ulong[][][] descriptorRegionIndices;
  // descriptor type by descriptor binding by descriptor set by stage
  VkDescriptorType[][][] descriptorTypes;
}

ExecutionStagesAnalysis analyzeExecutionStages(ExecutionStage[] stages, VkShaderModule[] shaderModules, DescriptorSetLayoutCollection descriptorSetLayoutCol, PipelineLayoutCollection pipelineLayoutCol, ulong initialInputSize) {
  ExecutionStagesAnalysis a;
  immutable ulong stageCount = stages.length;
  immutable ulong bufferCount = stageCount + 1;

  a.descriptorSetCount = 0;

  a.writeCommandBufferFns.length = stageCount;
  a.pipelineLayouts.length = stageCount;
  a.pipelineInfos.length = stageCount;
  a.descriptorSetLayouts.length = stageCount;
  a.descriptorRegionIndices.length = stageCount;
  a.descriptorTypes.length = stageCount;

  a.bufferRegions.length = bufferCount;

  a.descriptorTypeCounter = new DescriptorTypeCounter();

  ulong inputSize = initialInputSize;

  foreach(i, stage; stages) {
    ExecutionParameters p = stage.strategy.getExecutionParameters(inputSize);

    assert(p.regions.length > 0);
    assert(p.regions[0].size == inputSize);

    a.writeCommandBufferFns[i] = p.writeCommandBuffer;
    a.bufferRegions[i] = p.regions;

    a.descriptorSetCount += p.regions.length;

    ulong[] layoutIndices;
    layoutIndices.length = p.layouts.length;

    foreach(j, layout; p.layouts) {
      VkDescriptorSetLayoutBinding[] layoutBindings = processLayoutBindings(layout);
      layoutIndices[j] = descriptorSetLayoutCol.register(layoutBindings);
    }

    a.descriptorSetLayouts[i].length = p.descriptorSetIndices.length;
    a.descriptorRegionIndices[i].length = p.descriptorSetIndices.length;
    a.descriptorTypes[i].length = p.descriptorSetIndices.length;

    foreach(j, dsIndices; p.descriptorSetIndices) {
      a.descriptorSetLayouts[i][j] = descriptorSetLayoutCol.get(layoutIndices[dsIndices.layoutIndex]);
      a.descriptorRegionIndices[i][j] = dsIndices.regionIndices;

      BufferType[] layoutBufferTypes = p.layouts[dsIndices.layoutIndex];
      a.descriptorTypes[i][j].length = dsIndices.regionIndices.length;
      foreach(k, bufferType; layoutBufferTypes) {
        VkDescriptorType dsType = descriptorTypeOfBufferType(bufferType);
        a.descriptorTypes[i][j][k] = dsType;
        a.descriptorTypeCounter.add(dsType);
      }
    }

    ulong pipelineIndex = pipelineLayoutCol.register(tuple!(ulong[], VkPushConstantRange[])(layoutIndices, p.pushConstantRanges));
    a.pipelineLayouts[i] = pipelineLayoutCol.get(pipelineIndex);

    VkComputePipelineCreateInfo pipelineInfo = {
      stage: {
        stage: VK_SHADER_STAGE_COMPUTE_BIT,
        _module: shaderModules[stage.shaderModuleIndex],
        pName: stage.entryPoint.ptr
      },
     layout: a.pipelineLayouts[i]
    };

    a.pipelineInfos[i] = pipelineInfo;

    inputSize = p.outputSize;
  }

  a.bufferRegions[$-1] = [ MemoryRegion(uint.sizeof, inputSize / uint.sizeof) ];

  return a;
}


class ExecutionPipeline {
  private Device device;
  private VkShaderModule[] shaderModules;
  private VkPipeline[] pipelines;
  private DescriptorSetLayoutCollection descriptorSetLayoutCol;
  private PipelineLayoutCollection pipelineLayoutCol;
  private Memory memory;
  private DescriptorSetPool dsPool;
  private VkFence fence;
  private VkCommandPool commandPool;
  private VkCommandBuffer commandBuffer;

  private ulong bufferCount;

  this(Device d, ExecutionModule[] modules, ExecutionStage[] stages, ulong initialInputSize) {
    device = d;
    shaderModules = map!(m => createShaderModule(device.logicalDevice, m.shaderCode))(modules).array;

    bufferCount = stages.length + 1;

    // -- Collect and process execution parameters from stages

    descriptorSetLayoutCol = new DescriptorSetLayoutCollection(device);
    pipelineLayoutCol = new PipelineLayoutCollection(device, descriptorSetLayoutCol);

    ExecutionStagesAnalysis sa = analyzeExecutionStages(stages, shaderModules, descriptorSetLayoutCol, pipelineLayoutCol, initialInputSize);

    // -- Create pipelines
    
    pipelines.length = sa.pipelineInfos.length;
    enforceVk(vkCreateComputePipelines(device.logicalDevice, null, sa.pipelineInfos.length.to!uint, sa.pipelineInfos.ptr, null, pipelines.ptr));

    // -- Allocate memory and descriptor sets

    VkDescriptorSetLayout[] flatDescriptorSetLayouts = flatten(sa.descriptorSetLayouts);

    memory = new Memory(device, sa.bufferRegions);
    dsPool = new DescriptorSetPool(device, sa.descriptorTypeCounter.counts, flatDescriptorSetLayouts);

    // -- Write descriptor sets

    DescriptorSetWriter writer = new DescriptorSetWriter(device);
    ulong descriptorSetIndex = 0;

    foreach(i; iota(sa.descriptorRegionIndices.length)) {
      foreach(j; iota(sa.descriptorRegionIndices[i].length)) {
        foreach(k, regionIndex; sa.descriptorRegionIndices[i][j]) {
          VkDescriptorSet set = dsPool.sets[descriptorSetIndex];
          VkDescriptorType t = sa.descriptorTypes[i][j][k];

          RegionDescriptor regionDesc;
          VkBuffer buffer;
          if(regionIndex == sa.bufferRegions[i].length) {
            regionDesc = memory.getRegionDescriptor(i + 1, 0);
            buffer = memory.getBuffer(i + 1);
          } else {
            regionDesc = memory.getRegionDescriptor(i, regionIndex);
            buffer = memory.getBuffer(i);
          }

          writer.write(set, k.to!uint, t, buffer, regionDesc.bufferOffset, regionDesc.sizes.dataSize);
        }
        descriptorSetIndex++;
      }
    }

    writer.flush();

    // -- Allocate command buffer and fence

    VkCommandPoolCreateInfo commandPoolInfo = {
      queueFamilyIndex: device.queueFamilyIndex
    };

    enforceVk(vkCreateCommandPool(device.logicalDevice, &commandPoolInfo, null, &commandPool));

    VkCommandBufferAllocateInfo commandBufferAllocateInfo = {
      commandPool: commandPool,
      level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      commandBufferCount: 1
    };

    enforceVk(vkAllocateCommandBuffers(device.logicalDevice, &commandBufferAllocateInfo, &commandBuffer));

    VkFenceCreateInfo fenceInfo = {};

    enforceVk(vkCreateFence(device.logicalDevice, &fenceInfo, null, &fence));

    // -- Write command buffer

    VkCommandBufferBeginInfo beginInfo = {
      flags: VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    };

    enforceVk(vkBeginCommandBuffer(commandBuffer, &beginInfo));

    descriptorSetIndex = 0;
    foreach(i, stage; stages) {
      ulong descriptorSetLength = sa.descriptorRegionIndices[i].length;

      vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipelines[i]);
      sa.writeCommandBufferFns[i](commandBuffer, sa.pipelineLayouts[i], dsPool.sets[descriptorSetIndex..descriptorSetIndex + descriptorSetLength]);

      descriptorSetIndex += descriptorSetLength;
    }

    enforceVk(vkEndCommandBuffer(commandBuffer));
  }

  void cleanup() {
    descriptorSetLayoutCol.cleanup();
    pipelineLayoutCol.cleanup();
    dsPool.cleanup();
    memory.cleanup();

    pipelines.each!(p => vkDestroyPipeline(device.logicalDevice, p, null));
    shaderModules.each!(m => vkDestroyShaderModule(device.logicalDevice, m, null));
    vkDestroyCommandPool(device.logicalDevice, commandPool, null);
    vkDestroyFence(device.logicalDevice, fence, null);
  }

  T[] execute(T)(T[] data) {
    memory.writeRegion(0, 0, data);

    VkSubmitInfo submitInfo = {
      commandBufferCount: 1,
      pCommandBuffers: [commandBuffer].ptr
    };

    enforceVk(vkQueueSubmit(device.queue, 1, &submitInfo, fence));
    // TODO: retry after timeout
    enforceVk(vkQueueWaitIdle(device.queue));
    enforceVk(vkWaitForFences(device.logicalDevice, 1, [fence].ptr, true, 0));

    // writeln(memory.dumpMemory());

    return memory.copyRegion!T(bufferCount - 1, 0);
  }
}
