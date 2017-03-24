import std.algorithm.iteration;
import std.conv;
import std.typecons;
import std.range;
import std.stdio;

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

struct RegionDescriptor {
  MemorySizes sizes;
  ulong bufferOffset;
  ulong memoryOffset;
}

struct BufferDescriptor {
  MemorySizes sizes;
  ulong memoryOffset;
  RegionDescriptor[] regions;
}

class Memory {
  ulong memorySize;

  private Device device;
  private VkDeviceMemory memory;
  private VkBuffer[] buffers;
  private MemoryRegion[][] bufferRegions;
  private BufferDescriptor[] bufferDescriptors;

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
    bufferDescriptors.length = bufferRegions.length;

    foreach(i, regions; bufferRegions) {
      bufferDescriptors[i].memoryOffset = memorySize;

      ulong regionBufferOffset = 0;
      ulong regionMemoryOffset = memorySize;
      bufferDescriptors[i].regions.length = regions.length;

      foreach(j, region; regions) {
        ulong size = region.size();
        ulong blockSize = alignSize(size, device.getLimits().minStorageBufferOffsetAlignment);

        bufferDescriptors[i].regions[j] = RegionDescriptor(MemorySizes(size, blockSize), regionBufferOffset, regionMemoryOffset);

        regionBufferOffset += blockSize;
        regionMemoryOffset += blockSize;
      }

      bufferInfo.size = regionBufferOffset;
      enforceVk(vkCreateBuffer(device.logicalDevice, &bufferInfo, null, &buffers[i]));

      vkGetBufferMemoryRequirements(device.logicalDevice, buffers[i], &memoryRequirements);

      ulong bufferBlockSize = alignSize(bufferInfo.size, memoryRequirements.alignment);
      bufferDescriptors[i].sizes = MemorySizes(bufferInfo.size, bufferBlockSize);

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
      bufferOffset += bufferDescriptors[i].sizes.blockSize;
    }

    // -- Zero allocated memory (temporary)
    
    uint *mem;
    enforceVk(vkMapMemory(
        device.logicalDevice,
        memory,
        0,
        memorySize,
        0,
        castFrom!(uint**).to!(void**)(&mem)
    ));

    for(ulong i = 0; i < memorySize / uint.sizeof; i++) {
      *(mem + i) = 0;
    }

    vkUnmapMemory(device.logicalDevice, memory);
  }

  void cleanup() {
    each!(b => vkDestroyBuffer(device.logicalDevice, b, null))(buffers);
    vkFreeMemory(device.logicalDevice, memory, null);
  }

  RegionDescriptor getRegionDescriptor(ulong bufferIndex, ulong regionIndex) {
    assert(bufferIndex < bufferDescriptors.length);

    BufferDescriptor d = bufferDescriptors[bufferIndex];
    assert(regionIndex < d.regions.length);

    return d.regions[regionIndex];
  }

  BufferDescriptor getBufferDescriptor(ulong bufferIndex) {
    assert(bufferIndex < bufferDescriptors.length);
    return bufferDescriptors[bufferIndex];
  }

  VkBuffer getBuffer(ulong bufferIndex) {
    assert(bufferIndex < buffers.length);
    return buffers[bufferIndex];
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
    RegionDescriptor d = getRegionDescriptor(bufferIndex, regionIndex);
    return copyMemory!T(d.memoryOffset, d.sizes.dataSize);
  }

  T[] copyBuffer(T)(ulong bufferIndex) {
    BufferDescriptor d = getBufferDescriptor(bufferIndex);
    return copyMemory!T(offset, d.memoryOffset);
  }

  void writeRegion(T)(ulong bufferIndex, ulong regionIndex, T[] data) {
    RegionDescriptor d = getRegionDescriptor(bufferIndex, regionIndex);
    writeMemory!T(d.memoryOffset, d.sizes.dataSize, data);
  }

  uint[] dumpMemory() {
    return copyMemory!uint(0, memorySize);
  }
}
