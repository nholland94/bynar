import std.algorithm.iteration;
import std.array;
import std.conv;
import std.range;

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

class ExecutionPipeline {
  private Device device;
  private VkShaderModule[] shaderModules;
  private VkPipeline[] pipelines;
  private DescriptorSetLayoutCollection descriptorSetLayoutCol;
  private PipelineLayoutCollection pipelineLayoutCol;
  private Memory memory;
  private DescriptorSetPool dsPool;
  private VkCommandPool commandPool;
  private VkCommandBuffer commandBuffer;

  private ulong bufferCount;

  this(Device d, ExecutionModule[] modules, ExecutionStage[] stages, ulong initialInputSize) {
    device = d;
    shaderModules = map!(m => createShaderModule(device.logicalDevice, m.shaderCode))(modules).array;

    // -- Collect and process execution parameters from stages

    descriptorSetLayoutCol = new DescriptorSetLayoutCollection(device);
    pipelineLayoutCol = new PipelineLayoutCollection(device, descriptorSetLayoutCol);

    ulong[] pipelineLayoutIndices;
    WriteCommandBufferFn[] writeCommandBufferFns;
    MemoryRegion[][] bufferRegions;
    uint[] descriptorTypeCounts;
    VkDescriptorSetLayout[][] stageDescriptorSetLayouts;
    ulong[][][] stageDescriptorRegionIndices;
    VkDescriptorType[][][] stageDescriptorTypes;
    VkComputePipelineCreateInfo[] pipelineInfos;

    pipelineLayoutIndices.length = stages.length;
    writeCommandBufferFns.length = stages.length;
    pipelines.length = stages.length;
    stageDescriptorSetLayouts.length = stages.length;
    stageDescriptorRegionIndices.length = stages.length;
    stageDescriptorTypes.length = stages.length;
    pipelineInfos.length = stages.length;

    bufferRegions.length = stages.length + 1;

    // This is dependent on the input attachment type being the highest value in the api
    descriptorTypeCounts.length = VkDescriptorType.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT + 1;

    ulong inputSize = initialInputSize;
    ulong descriptorSetCount = 0;

    bufferCount = stages.length + 1;

    foreach(i, stage; stages) {
      ExecutionParameters p = stage.strategy.getExecutionParameters(inputSize);

      assert(p.regions.length > 0);
      assert(p.regions[0].size == inputSize);

      writeCommandBufferFns[i] = p.writeCommandBuffer;
      bufferRegions[i] = p.regions;

      descriptorSetCount += p.regions.length;

      ulong[] layoutIndices;
      layoutIndices.length = p.layouts.length;

      foreach(j, layout; p.layouts) {
        VkDescriptorSetLayoutBinding[] layoutBindings = processLayoutBindings(layout);
        layoutIndices[j] = descriptorSetLayoutCol.register(layoutBindings);
      }

      stageDescriptorSetLayouts[i].length = p.descriptorSetIndices.length;
      stageDescriptorRegionIndices[i].length = p.descriptorSetIndices.length;
      stageDescriptorTypes[i].length = p.descriptorSetIndices.length;

      foreach(j, dsIndices; p.descriptorSetIndices) {
        stageDescriptorSetLayouts[i][j] = descriptorSetLayoutCol.get(layoutIndices[dsIndices.layoutIndex]);
        stageDescriptorRegionIndices[i][j] = dsIndices.regionIndices;

        BufferType[] layoutBufferTypes = p.layouts[dsIndices.layoutIndex];
        stageDescriptorTypes[i][j].length = dsIndices.regionIndices.length;
        foreach(k, bufferType; layoutBufferTypes) {
          VkDescriptorType dsType = descriptorTypeOfBufferType(bufferType);
          stageDescriptorTypes[i][j][k] = dsType;
          descriptorTypeCounts[dsType]++;
        }
      }

      pipelineLayoutIndices[i] = pipelineLayoutCol.register(layoutIndices);
      VkPipelineLayout pipelineLayout = pipelineLayoutCol.get(pipelineLayoutIndices[i]);

      VkComputePipelineCreateInfo pipelineInfo = {
        stage: {
          stage: VK_SHADER_STAGE_COMPUTE_BIT,
          _module: shaderModules[stage.shaderModuleIndex],
          pName: stage.entryPoint.ptr
        },
       layout: pipelineLayout
      };

      pipelineInfos[i] = pipelineInfo;

      inputSize = p.outputSize;
    }

    bufferRegions[$-1] = [ MemoryRegion(uint.sizeof, inputSize / uint.sizeof) ];

    // -- Create pipelines
    
    pipelines.length = pipelineInfos.length;
    enforceVk(vkCreateComputePipelines(device.logicalDevice, null, pipelineInfos.length.to!uint, pipelineInfos.ptr, null, pipelines.ptr));

    // -- Allocate memory and descriptor sets

    VkDescriptorSetLayout[] descriptorSetLayouts = flatten(stageDescriptorSetLayouts);

    memory = new Memory(device, bufferRegions);
    dsPool = new DescriptorSetPool(device, descriptorTypeCounts, descriptorSetLayouts);

    // -- Write descriptor sets

    DescriptorSetWriter writer = new DescriptorSetWriter(device);
    ulong descriptorSetIndex = 0;

    foreach(i; iota(stageDescriptorRegionIndices.length)) {
      foreach(j; iota(stageDescriptorRegionIndices[i].length)) {
        foreach(k, regionIndex; stageDescriptorRegionIndices[i][j]) {
          VkDescriptorSet set = dsPool.sets[descriptorSetIndex];
          VkDescriptorType t = stageDescriptorTypes[i][j][k];

          RegionDescriptor regionDesc;
          VkBuffer buffer;
          if(regionIndex == bufferRegions[i].length) {
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

    // -- Allocate command buffer

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

    // -- Write command buffer

    VkCommandBufferBeginInfo beginInfo = {
      flags: VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    };

    enforceVk(vkBeginCommandBuffer(commandBuffer, &beginInfo));

    descriptorSetIndex = 0;
    foreach(i, stage; stages) {
      ulong descriptorSetLength = stageDescriptorRegionIndices[i].length;

      vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipelines[i]);
      writeCommandBufferFns[i](commandBuffer, pipelineLayoutCol.get(pipelineLayoutIndices[i]), dsPool.sets[descriptorSetIndex..descriptorSetIndex + descriptorSetLength]);

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
  }

  T[] execute(T)(T[] data) {
    memory.writeRegion(0, 0, data);

    VkSubmitInfo submitInfo = {
      commandBufferCount: 1,
      pCommandBuffers: [commandBuffer].ptr
    };

    enforceVk(vkQueueSubmit(device.queue, 1, &submitInfo, null));
    enforceVk(vkQueueWaitIdle(device.queue));

    // writeln(memory.dumpMemory());

    return memory.copyRegion!T(bufferCount - 1, 0);
  }
}
