import std.functional;
import std.algorithm.iteration;
import std.array;
import std.conv;
import std.file;
import std.range;
import std.stdio;
import std.string;
import std.typecons;

import erupted;

import common;
import constructors;

Nullable!uint findMemoryTypeIndex(VkPhysicalDeviceMemoryProperties memoryProperties, VkMemoryPropertyFlags flags, VkDeviceSize minimumSize) {
  for(uint i = 0; i < memoryProperties.memoryTypeCount; i++) {
    VkMemoryType memoryType = memoryProperties.memoryTypes[i];
    VkDeviceSize memoryHeapSize = memoryProperties.memoryHeaps[memoryType.heapIndex].size;

    if((memoryType.propertyFlags & flags) && (memoryHeapSize >= minimumSize)) {
      return Nullable!uint(i);
    }
  }

  return Nullable!uint.init;
}

ulong count2D(T)(T[][] mat) {
  ulong size = 0;
  foreach(vec; mat) size += vec.length;
  return size;
}

uint[] loadShaderCodeBuffer(string filename) {
  return castFrom!(void[]).to!(uint[])(read(filename));
}

struct BufferCollection {
  VkBuffer[] buffers;
  size_t[] dataSizes;
  size_t[] bufferSizes;

  this(VkDevice device, PipelineConstructorInterface[] constructors, size_t inputSize, uint[] queueFamilyIndices, VkPhysicalDeviceLimits limits) {
    // -- Calculate buffer data sizes from constructors
    
    this.dataSizes.length = constructors.length + 1;
    this.dataSizes[0] = inputSize;

    foreach(i; iota(constructors.length)) {
      PipelineConstructorInterface constructor = constructors[i];
      constructor.setSize(dataSizes[i], limits.minStorageBufferOffsetAlignment);
      dataSizes[i] = constructor.inputBufferSize();
      dataSizes[i + 1] = constructor.outputBufferSize();
    }


    // -- Intialize buffers and adjust buffer sizes for memory alignment

    auto roundTo = function (size_t v, size_t d) => v + (d - v % d);

    this.buffers.length = dataSizes.length;
    this.bufferSizes.length = dataSizes.length;

    VkBufferCreateInfo bufferInfo = {
      size: 0,
      usage: VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
      sharingMode: VK_SHARING_MODE_EXCLUSIVE,
      queueFamilyIndexCount: queueFamilyIndices.length.to!uint,
      pQueueFamilyIndices: queueFamilyIndices.ptr
    };

    VkMemoryRequirements memoryRequirements;

    foreach(i; iota(buffers.length)) {
      bufferInfo.size = this.dataSizes[i];
      enforceVk(vkCreateBuffer(device, &bufferInfo, null, this.buffers.ptr + i));
      vkGetBufferMemoryRequirements(device, this.buffers[i], &memoryRequirements);
      this.bufferSizes[i] = roundTo(this.dataSizes[i], memoryRequirements.alignment);
    }

    writeln("data sizes: ", map!((s) => format("0x%04x", s))(this.dataSizes));
    writeln("buffer sizes: ", map!((s) => format("0x%04x", s))(this.bufferSizes));
    writefln("0x%04x", memoryRequirements.alignment);
  }

  size_t requiredMemorySize() {
    return fold!"a+b"(this.bufferSizes);
  }

  void bindMemory(VkDevice device, VkDeviceMemory memory) {
    ulong bufferOffset = 0;

    foreach(i, buffer; this.buffers) {
      vkBindBufferMemory(device, buffer, memory, bufferOffset);
      bufferOffset += this.bufferSizes[i];
    }
  }

  void cleanup(VkDevice device) {
    each!((buffer) => vkDestroyBuffer(device, buffer, null))(this.buffers);
  }
}

struct PipelineDescriptionCollection {
  uint descriptorCount;
  uint descriptorSetCount;

  // collections
  VkDescriptorSetLayout[] descriptorSetLayouts;
  VkPipelineLayout[] pipelineLayouts;
  uint[][] shaderCodeBuffers;
  VkShaderModule[] shaderModules;
  DescriptorSetData[][][] descriptorSetDataSets;
  string[] pipelineShaderModuleEntryPoints;
  uint[] descriptorTypeCounts;

  // bindings
  ulong[][] descriptorSetLayoutIndicesByPipeline;
  ulong[] shaderModuleIndexByPipeline;
  VkDescriptorSetLayout[] descriptorSetLayoutsByDescriptorSet;

  this(VkDevice device, PipelineConstructorInterface[] constructors, VkBuffer[] buffers) {
    void createLayouts() {
      const ulong bindingSetsGrowSize = 64;
      uint bindingSetCount = 0;
      VkDescriptorSetLayoutBinding[][] bindingSets;
      bindingSets.length = bindingSetsGrowSize;

      bool bindingSetsEqual(VkDescriptorSetLayoutBinding[] a, VkDescriptorSetLayoutBinding[] b) {
        if(a.length != b.length) return false;

        for(int i = 0; i < a.length; i++) {
          if(a[i] != b[i]) return false;
        }

        return true;
      }

      ulong addBindingSet(VkDescriptorSetLayoutBinding[] bindingSet) {
        for(int i = 0; i < bindingSetCount; i++) {
          if(bindingSetsEqual(bindingSets[i], bindingSet)) return i;
        }

        if(bindingSetCount == bindingSets.length)
          bindingSets.length += bindingSetsGrowSize;

        bindingSets[bindingSetCount] = bindingSet;
        return bindingSetCount++;
      }

      VkDescriptorSetLayout createLayout(VkDescriptorSetLayoutBinding[] bindings) {
        VkDescriptorSetLayoutCreateInfo layoutInfo = {
          bindingCount: bindings.length.to!uint,
          pBindings: bindings.ptr
        };

        VkDescriptorSetLayout layout;
        enforceVk(vkCreateDescriptorSetLayout(device, &layoutInfo, null, &layout));

        return layout;
      }

      ulong[] addConstructorLayoutBindings(PipelineConstructorInterface constructor) {
        return array(map!addBindingSet(constructor.descriptorSetLayoutBindings()));
      }

      this.descriptorSetLayoutIndicesByPipeline = array(map!addConstructorLayoutBindings(constructors));
      // ulong[][] layoutIndices = array!(ulong[][])(map!((c) => map!addBindingSet(c.descriptorSetLayoutBindings()))(this.constructors));

      // truncate buffered length before mapping
      bindingSets.length = bindingSetCount;
      this.descriptorSetLayouts = array(map!createLayout(bindingSets));
    }

    void collectInformation() {
      this.descriptorSetDataSets.length = constructors.length;
      this.shaderModuleIndexByPipeline.length = constructors.length;
      this.pipelineShaderModuleEntryPoints.length = constructors.length;
      // This is dependent on the input attachment type being the highest value in the api
      this.descriptorTypeCounts.length = VkDescriptorType.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT + 1;

      ulong[][] processedLayoutIndices;
      string[] processedShaderNames;

      bool layoutIndicesAlreadyProcessed(ulong[] layoutIndices) {
        foreach(processedIndices; processedLayoutIndices) {
          if(processedIndices.length != layoutIndices.length) continue;

          bool equal = true;
          foreach(i, index; layoutIndices) {
            if(index != processedIndices[i]) {
              equal = false;
              break;
            }
          }

          if(equal) return true;
        }

        return false;
      }

      void addPipelineLayout(ulong[] layoutIndices) {
        if(layoutIndicesAlreadyProcessed(layoutIndices)) return;

        VkDescriptorSetLayout indexLayout(ulong index) { return this.descriptorSetLayouts[index]; }
        VkDescriptorSetLayout[] layouts = array(map!indexLayout(layoutIndices));

        VkPipelineLayoutCreateInfo layoutInfo = {
          setLayoutCount: layouts.length.to!uint,
          pSetLayouts: layouts.ptr
        };

        VkPipelineLayout pipelineLayout;
        enforceVk(vkCreatePipelineLayout(device, &layoutInfo, null, &pipelineLayout));

        this.pipelineLayouts[++this.pipelineLayouts.length - 1] = pipelineLayout;
        processedLayoutIndices[++processedLayoutIndices.length - 1] = layoutIndices;
      }

      ulong addShaderModule(string shaderName) {
        foreach(i, processedShaderName; processedShaderNames) {
          if(shaderName == processedShaderName) return i;
        }

        uint[] shaderCodeBuffer = loadShaderCodeBuffer(shaderName);

        VkShaderModuleCreateInfo moduleInfo = {
          codeSize: shaderCodeBuffer.length * uint.sizeof,
          pCode: shaderCodeBuffer.ptr
        };

        VkShaderModule shaderModule;
        enforceVk(vkCreateShaderModule(device, &moduleInfo, null, &shaderModule));

        this.shaderCodeBuffers[++this.shaderCodeBuffers.length - 1] = shaderCodeBuffer;
        this.shaderModules[++this.shaderModules.length - 1] = shaderModule;
        processedShaderNames[++processedShaderNames.length - 1] = shaderName;

        return this.shaderModules.length - 1;
      }

      foreach(i, constructor; constructors) {
        this.descriptorSetDataSets[i] = constructor.descriptorSetDataSets(buffers[i], buffers[i + 1]);
        this.descriptorSetCount += this.descriptorSetDataSets[i].length;

        ulong[] layoutIndices = this.descriptorSetLayoutIndicesByPipeline[i];
        addPipelineLayout(layoutIndices);

        this.shaderModuleIndexByPipeline[i] = addShaderModule(constructor.shaderModuleName());
        this.pipelineShaderModuleEntryPoints[i] = constructor.shaderModuleEntryPoint();

        foreach(dataSet; this.descriptorSetDataSets[i]) {
          this.descriptorCount += dataSet.length;

          foreach(dataPoint; dataSet) {
            ulong layoutIndex = layoutIndices[dataPoint.layoutIndex];
            this.descriptorSetLayoutsByDescriptorSet[++this.descriptorSetLayoutsByDescriptorSet.length - 1] = this.descriptorSetLayouts[layoutIndex];
            this.descriptorTypeCounts[dataPoint.descriptorType]++;
          }
        }
      }
    }

    createLayouts();
    collectInformation();
  }

  void cleanup(VkDevice device) {
    each!((l) => vkDestroyDescriptorSetLayout(device, l, null))(this.descriptorSetLayouts);
    each!((l) => vkDestroyPipelineLayout(device, l, null))(this.pipelineLayouts);
    each!((m) => vkDestroyShaderModule(device, m, null))(this.shaderModules);
  }
}

struct PipelineCollection {
  VkDescriptorPool descriptorPool;
  VkDescriptorSet[] descriptorSets;
  VkPipeline[] pipelines;
  VkCommandBuffer commandBuffer;

  this(VkDevice device, PipelineConstructorInterface[] constructors, VkBuffer[] buffers, PipelineDescriptionCollection desc, VkCommandPool commandPool) {
    VkDescriptorPoolSize[] poolSizes;

    for(int i = 0; i < desc.descriptorTypeCounts.length; i++) {
      if(desc.descriptorTypeCounts[i] > 0) {
        VkDescriptorPoolSize poolSize = {
          type: castFrom!int.to!VkDescriptorType(i),
          descriptorCount: desc.descriptorTypeCounts[i]
        };

        poolSizes.length++;
        poolSizes[poolSizes.length - 1] = poolSize;
      }
    }

    VkDescriptorPoolCreateInfo poolInfo = {
      maxSets: desc.descriptorSetCount,
      poolSizeCount: poolSizes.length.to!uint,
      pPoolSizes: poolSizes.ptr
    };

    enforceVk(vkCreateDescriptorPool(device, &poolInfo, null, &this.descriptorPool));

    writeln(desc.descriptorSetLayoutsByDescriptorSet.length);

    VkDescriptorSetAllocateInfo descriptorSetAllocateInfo = {
      descriptorPool: this.descriptorPool,
      descriptorSetCount: desc.descriptorSetCount,
      pSetLayouts: desc.descriptorSetLayoutsByDescriptorSet.ptr
    };

    this.descriptorSets.length = desc.descriptorSetCount;
    enforceVk(vkAllocateDescriptorSets(device, &descriptorSetAllocateInfo, this.descriptorSets.ptr));

    VkComputePipelineCreateInfo[] pipelineInfos;
    pipelineInfos.length = constructors.length;

    foreach(i, constructor; constructors) {
      VkPipelineLayout pipelineLayout = desc.pipelineLayouts[i];

      ulong shaderModuleIndex = desc.shaderModuleIndexByPipeline[i];

      VkComputePipelineCreateInfo pipelineInfo = {
        stage: {
          stage: VK_SHADER_STAGE_COMPUTE_BIT,
          _module: desc.shaderModules[shaderModuleIndex],
          pName: desc.pipelineShaderModuleEntryPoints[i].ptr
        },
        layout: pipelineLayout
      };

      pipelineInfos[i] = pipelineInfo;
    }

    this.pipelines.length = pipelineInfos.length;
    enforceVk(vkCreateComputePipelines(device, null, pipelineInfos.length.to!uint, pipelineInfos.ptr, null, this.pipelines.ptr));

    VkCommandBufferAllocateInfo commandBufferAllocateInfo = {
      commandPool: commandPool,
      level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      commandBufferCount: 1
    };

    enforceVk(vkAllocateCommandBuffers(device, &commandBufferAllocateInfo, &this.commandBuffer));
  }

  private void writeDescriptorSets(VkDevice device, DescriptorSetData[][][] descriptorSetDataSets) {
    writeln(this.descriptorSets);
    writeln(descriptorSetDataSets);

    VkWriteDescriptorSet[] writeCommands;
    ulong descriptorSetIndex = 0;

    foreach(dataSetsIndex, dataSets; descriptorSetDataSets) {
      foreach(dataSetIndex, dataSet; dataSets) {
        VkDescriptorSet descriptorSet = this.descriptorSets[descriptorSetIndex++];
        ulong writeCommandsBase = writeCommands.length;
        writeCommands.length += dataSet.length;

        foreach(dataIndex, data; dataSet) {
          VkWriteDescriptorSet writeCommand = {
            dstSet: descriptorSet,
            dstBinding: data.binding,
            descriptorCount: 1,
            descriptorType: data.descriptorType,
            pBufferInfo: &descriptorSetDataSets[dataSetsIndex][dataSetIndex][dataIndex].bufferInfo
          };

          writeCommands[writeCommandsBase + dataIndex] = writeCommand;
        }
      }
    }

    vkUpdateDescriptorSets(device, writeCommands.length.to!uint, writeCommands.ptr, 0, null);
  }

  private void writeCommandBuffer(VkDevice device, PipelineConstructorInterface[] constructors, VkPipelineLayout[] pipelineLayouts, DescriptorSetData[][][] descriptorSetDataSets) {
    const VkCommandBufferBeginInfo beginInfo = {
      flags: VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    };

    enforceVk(vkBeginCommandBuffer(this.commandBuffer, &beginInfo));

    ulong descriptorSetOffset = 0;

    foreach(i, constructor; constructors) {
      ulong pipelineDescriptorSetCount = descriptorSetDataSets[i].length;
      VkDescriptorSet[] pipelineDescriptorSets = descriptorSets[descriptorSetOffset..descriptorSetOffset + pipelineDescriptorSetCount];
      descriptorSetOffset += pipelineDescriptorSetCount;

      vkCmdBindPipeline(this.commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipelines[i]);
      constructor.writeCommands(this.commandBuffer, pipelineLayouts[i], pipelineDescriptorSets);
    }

    enforceVk(vkEndCommandBuffer(this.commandBuffer));
  }

  void prepare(VkDevice device, PipelineConstructorInterface[] constructors, PipelineDescriptionCollection desc) {
    this.writeDescriptorSets(device, desc.descriptorSetDataSets);
    this.writeCommandBuffer(device, constructors, desc.pipelineLayouts, desc.descriptorSetDataSets);
  }

  void submitQueue(VkQueue queue) {
    const VkSubmitInfo submitInfo = {
      commandBufferCount: 1,
      pCommandBuffers: [this.commandBuffer].ptr
    };

    enforceVk(vkQueueSubmit(queue, 1, &submitInfo, null));
    enforceVk(vkQueueWaitIdle(queue));
  }

  void cleanup(VkDevice device) {
    each!((p) => vkDestroyPipeline(device, p, null))(this.pipelines);
    // vkFreeDescriptorSets(device, this.descriptorPool, this.descriptorSets.length.to!uint, this.descriptorSets.ptr);
    vkDestroyDescriptorPool(device, this.descriptorPool, null);
  }
}

VkDeviceMemory allocateDeviceMemory(VkDevice device, VkPhysicalDeviceMemoryProperties memoryProperties, size_t requiredMemorySize) {
  const VkMemoryPropertyFlags memoryType = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
  auto memoryTypeIndex = findMemoryTypeIndex(memoryProperties, memoryType, requiredMemorySize);

  const VkMemoryAllocateInfo allocateInfo = {
    allocationSize: requiredMemorySize,
    memoryTypeIndex: memoryTypeIndex
  };

  VkDeviceMemory memory;
  enforceVk(vkAllocateMemory(device, &allocateInfo, null, &memory));

  return memory;
}

void copyInput(T)(VkDevice device, VkDeviceMemory memory, T[] data) {
  T* mappedMemory;

  enforceVk(vkMapMemory(device, memory, 0, data.length * T.sizeof, 0, castFrom!(T**).to!(void**)(&mappedMemory)));

  foreach(i; iota(data.length)) {
    *(mappedMemory + i) = data[i];
  }

  vkUnmapMemory(device, memory);
}

T[] copyOutput(T)(VkDevice device, VkDeviceMemory memory, BufferCollection bufferCol) {
  VkBuffer outputBuffer = bufferCol.buffers[$-1];

  // size_t outputSize = bufferCol.dataSizes[$-1];
  // assert(outputSize % T.sizeof == 0);
  writeln(bufferCol.dataSizes);
  writeln(T.sizeof);
  size_t outputSize = bufferCol.dataSizes[$-1] - (bufferCol.dataSizes[$-1] % T.sizeof);

  T* mappedMemory;
  T[] output;
  output.length = outputSize / T.sizeof;

  size_t outputOffset = fold!"a+b"(bufferCol.bufferSizes[0..$-1]);

  enforceVk(vkMapMemory(device, memory, outputOffset, outputSize, 0, castFrom!(T**).to!(void**)(&mappedMemory)));

  foreach(i; iota(output.length)) {
    output[i] = *(mappedMemory + i);
  }

  vkUnmapMemory(device, memory);

  return output;
}

T[] executeConstructors(T)(VkPhysicalDeviceMemoryProperties deviceMemoryProperties, VkPhysicalDeviceLimits limits, VkDevice device, VkQueue queue, uint queueFamilyIndex, PipelineConstructorInterface[] constructors, T[] data) {
  VkCommandPoolCreateInfo commandPoolInfo = {
    queueFamilyIndex: queueFamilyIndex
  };

  VkCommandPool commandPool;
  enforceVk(vkCreateCommandPool(device, &commandPoolInfo, null, &commandPool));

  BufferCollection bufferCol = BufferCollection(device, constructors, data.length * T.sizeof, [queueFamilyIndex], limits);
  VkDeviceMemory memory = allocateDeviceMemory(device, deviceMemoryProperties, bufferCol.requiredMemorySize());
  bufferCol.bindMemory(device, memory);

  PipelineDescriptionCollection pipelineDescriptionCol = PipelineDescriptionCollection(device, constructors, bufferCol.buffers);

  PipelineCollection pipelineCol = PipelineCollection(device, constructors, bufferCol.buffers, pipelineDescriptionCol, commandPool);

  pipelineCol.prepare(device, constructors, pipelineDescriptionCol);

  copyInput!T(device, memory, data);
  pipelineCol.submitQueue(queue);
  T[] output = copyOutput!T(device, memory, bufferCol);

  T* mappedMemory;
  T[] memoryBuffer;
  memoryBuffer.length = bufferCol.requiredMemorySize() / T.sizeof;

  enforceVk(vkMapMemory(device, memory, 0, bufferCol.requiredMemorySize().to!uint, 0, castFrom!(T**).to!(void**)(&mappedMemory)));

  foreach(i; iota(memoryBuffer.length)) {
    memoryBuffer[i] = *(mappedMemory + i);
  }

  vkUnmapMemory(device, memory);

  writeln("Memory after execution: ", memoryBuffer);

  pipelineCol.cleanup(device);
  pipelineDescriptionCol.cleanup(device);
  bufferCol.cleanup(device);

  vkFreeMemory(device, memory, null);
  vkDestroyCommandPool(device, commandPool, null);

  return output;
}
