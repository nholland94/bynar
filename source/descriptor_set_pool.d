import std.algorithm.iteration;
import std.conv;
import std.range;

import erupted;

import common;
import device;

class DescriptorSetPool {
  private Device device;
  VkDescriptorPool pool;
  VkDescriptorSet[] sets;

  this(Device device, uint[] descriptorTypeCounts, VkDescriptorSetLayout[] layouts) {
    this.device = device;

    VkDescriptorPoolSize consDescriptorPoolSize(ulong i) {
      VkDescriptorPoolSize poolSize = {
        type: castFrom!ulong.to!VkDescriptorType(i),
        descriptorCount: descriptorTypeCounts[i]
      };

      return poolSize;
    }

    VkDescriptorPoolSize[] poolSizes = map!consDescriptorPoolSize(iota(descriptorTypeCounts.length)).array;

    VkDescriptorPoolCreateInfo poolInfo = {
      maxSets: layouts.length.to!uint,
      poolSizeCount: poolSizes.length.to!uint,
      pPoolSizes: poolSizes.ptr
    };

    enforceVk(vkCreateDescriptorPool(device.logicalDevice, &poolInfo, null, &pool));

    VkDescriptorSetAllocateInfo descriptorSetAllocateInfo = {
      descriptorPool: pool,
      descriptorSetCount: layouts.length.to!uint,
      pSetLayouts: layouts.ptr
    };

    sets.length = layouts.length;
    enforceVk(vkAllocateDescriptorSets(device.logicalDevice, &descriptorSetAllocateInfo, sets.ptr));
  }

  void cleanup() {
    // vkFreeDescriptorSets(device.logicalDevice, pool, sets.length.to!uint, sets.ptr);
    vkDestroyDescriptorPool(device.logicalDevice, pool, null);
  }
}
