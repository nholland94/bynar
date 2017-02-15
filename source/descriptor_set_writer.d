import std.algorithm.iteration;
import std.conv;

import erupted;

import common;
import device;

class DescriptorSetWriter {
  private Device device;
  private VkDescriptorBufferInfo[] bufferInfos;
  private VkWriteDescriptorSet[] cmdBuffer;

  this(Device d) {
    device = d;
  }

  void write(VkDescriptorSet set, uint binding, VkDescriptorType t, VkBuffer buffer, ulong offset, ulong size) {
    VkDescriptorBufferInfo bufferInfo = {
      buffer: buffer,
      offset: offset,
      range: size
    };

    push(bufferInfos, bufferInfo);

    VkWriteDescriptorSet writeCommand = {
      dstSet: set,
      dstBinding: binding,
      descriptorCount: 1,
      descriptorType: t,
      pBufferInfo: &bufferInfos[$-1]
    };

    push(cmdBuffer, writeCommand);
  }

  void flush() {
    vkUpdateDescriptorSets(device.logicalDevice, cmdBuffer.length.to!uint, cmdBuffer.ptr, 0, null);
  }
}
