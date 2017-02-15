import std.algorithm.iteration;
import std.conv;
import std.typecons;
import std.range;

import erupted;

import common;
import device;

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

struct MemoryRegion {
  ulong elementSize;
  ulong count;

  @property ulong size() { return elementSize * count; }
}

struct MemorySizes {
  ulong dataSize;
  ulong blockSize;
}

class Memory {
  ulong memorySize;
  VkDeviceMemory memory;
  VkBuffer[] buffers;

  private Device device;

  private MemoryRegion[][] bufferRegions;
  private MemorySizes[] bufferSizes;
  private MemorySizes[][] regionSizes;

  this(Device device, MemoryRegion[][] bufferRegions) {
    this.device = device;
    this.bufferRegions = bufferRegions;

    // -- Collect buffers, sizes, and offsets from regions

    VkBufferCreateInfo bufferInfo = {
      size: 0,
      usage: VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
      sharingMode: VK_SHARING_MODE_EXCLUSIVE,
      queueFamilyIndexCount: 1,
      pQueueFamilyIndices: [device.queueFamilyIndex].ptr
    };

    VkMemoryRequirements memoryRequirements;

    memorySize = 0;
    buffers.length = bufferRegions.length;
    bufferSizes.length = bufferRegions.length;
    regionSizes.length = bufferRegions.length;

    foreach(i, regions; bufferRegions) {
      ulong regionOffset = 0;
      regionSizes[i].length = regions.length;

      foreach(j, region; regions) {
        ulong size = region.size();
        ulong blockSize = alignSize(size, device.getLimits().minStorageBufferOffsetAlignment);
        MemorySizes regionSize = { size, blockSize };
        regionSizes[i][j] = regionSize;
        regionOffset += blockSize;
      }

      bufferInfo.size = regionOffset;
      enforceVk(vkCreateBuffer(device.logicalDevice, &bufferInfo, null, &buffers[i]));

      vkGetBufferMemoryRequirements(device.logicalDevice, buffers[i], &memoryRequirements);

      ulong bufferBlockSize = alignSize(bufferInfo.size, memoryRequirements.alignment);
      MemorySizes bufferSize = { bufferInfo.size, bufferBlockSize };
      bufferSizes[i] = bufferSize;
      memorySize += bufferBlockSize;
    }

    // -- Allocate device memory

    const VkMemoryPropertyFlags requiredType = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uint memoryTypeIndex = findMemoryTypeIndex(device.getMemoryProperties(), requiredType, memorySize);

    const VkMemoryAllocateInfo allocateInfo = {
      allocationSize: memorySize,
      memoryTypeIndex: memoryTypeIndex
    };

    enforceVk(vkAllocateMemory(device.logicalDevice, &allocateInfo, null, &memory));

    // -- Bind buffers to memory

    ulong bufferOffset = 0;

    foreach(i, buffer; buffers) {
      vkBindBufferMemory(device.logicalDevice, buffer, memory, bufferOffset);
      bufferOffset += bufferSizes[i].blockSize;
    }
  }

  void cleanup() {
    each!(b => vkDestroyBuffer(device.logicalDevice, b, null))(buffers);
    vkFreeMemory(device.logicalDevice, memory, null);
  }

  Tuple!(VkBuffer, ulong, ulong) getRegion(ulong bufferIndex, ulong regionIndex) {
    assert(bufferIndex < bufferSizes.length);

    ulong offset;

    foreach(i, bufferSize; bufferSizes) {
      if(i == bufferIndex) {
        assert(regionIndex < regionSizes[i].length);

        foreach(j, regionSize; regionSizes[i]) {
          if(j == regionIndex) {
            return tuple!(VkBuffer, ulong, ulong)(buffers[i], offset, regionSize.dataSize);
          } else {
            offset += regionSize.blockSize;
          }
        }
      } else {
        offset += bufferSize.blockSize;
      }
    }

    throw new Exception("Failed to get region");
  }

  private T[] copyMemory(T)(ulong offset, ulong size) {
    assert(size % T.sizeof == 0);
    assert(offset + size <= memorySize);

    T* mem;
    T[] data;
    data.length = size / T.sizeof;

    enforceVk(vkMapMemory(
        device.logicalDevice,
        memory,
        offset,
        size,
        0,
        castFrom!(T**).to!(void**)(&mem)
    ));

    foreach(i; iota(data.length)) {
      data[i] = *(mem + i);
    }

    vkUnmapMemory(device.logicalDevice, memory);

    return data;
  }

  private void writeMemory(T)(ulong offset, ulong size, T[] data) {
    assert(size % T.sizeof == 0);
    assert(offset + size <= memorySize);

    T* mem;

    enforceVk(vkMapMemory(
        device.logicalDevice,
        memory,
        offset,
        size,
        0,
        castFrom!(T**).to!(void**)(&mem)
    ));

    foreach(i, el; data) {
      *(mem + i) = data[i];
    }

    vkUnmapMemory(device.logicalDevice, memory);
  }

  T[] copyRegion(T)(ulong bufferIndex, ulong regionIndex) {
    VkBuffer buffer;
    ulong offset, size;
    destruct!(buffer, offset, size) = getRegion(bufferIndex, regionIndex);
    return copyMemory!T(offset, size);
  }

  T[] copyBuffer(T)(ulong bufferIndex) {
    assert(bufferIndex < bufferSizes.length);

    auto sumBlockSize = function (a, b) => a.blockSize + b.blockSize;
    ulong offset = fold!sumBlockSize(bufferSizes[0..bufferIndex]);
    return copyMemory!T(offset, bufferSizes[bufferIndex].dataSize);
  }

  void writeRegion(T)(ulong bufferIndex, ulong regionIndex, T[] data) {
    VkBuffer buffer;
    ulong offset, size;
    destruct!(buffer, offset, size) = getRegion(bufferIndex, regionIndex);
    writeMemory!T(offset, size, data);
  }

  uint[] dumpMemory() {
    return copyMemory!uint(0, memorySize);
  }
}
