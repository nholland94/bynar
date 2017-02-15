import std.array;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.conv;
import std.typecons;

import erupted;

import common;
import device;

abstract class AtomicKeyedCollection(K,V) {
  K[] keys;
  V[] values;

  abstract bool keysEqual(K, K);

  void addKey(K key) { push(keys, key); }
  abstract void addValue(K key);

  ulong register(K key) {
    ulong index = countUntil!((a, b) => this.keysEqual(a, b))(keys, key);
    if(index == -1) {
      addKey(key);
      addValue(key);
      return values.length - 1;
    } else {
      return index;
    }
  }

  K getKey(ulong index) { return keys[index]; }
  V get(ulong index) { return values[index]; }
}

class DescriptorSetLayoutCollection : AtomicKeyedCollection!(VkDescriptorSetLayoutBinding[], VkDescriptorSetLayout) {
  private Device device;

  this(Device device) {
    this.device = device;
  }

  override bool keysEqual(VkDescriptorSetLayoutBinding[] a, VkDescriptorSetLayoutBinding[] b) {
    return arrayEqual(a, b);
  }

  override void addValue(VkDescriptorSetLayoutBinding[] bindings) {
    VkDescriptorSetLayoutCreateInfo layoutInfo = {
      bindingCount: bindings.length.to!uint,
      pBindings: bindings.ptr
    };

    values.length++;
    enforceVk(vkCreateDescriptorSetLayout(device.logicalDevice, &layoutInfo, null, &values[$-1]));
  }

  void cleanup() {
    each!(v => vkDestroyDescriptorSetLayout(device.logicalDevice, v, null))(values);
  }
}

class PipelineLayoutCollection : AtomicKeyedCollection!(ulong[], VkPipelineLayout) {
  private Device device;
  private DescriptorSetLayoutCollection dsLayoutCollection;

  this(Device device, DescriptorSetLayoutCollection dsLayoutCollection) {
    this.device = device;
    this.dsLayoutCollection = dsLayoutCollection;
  }

  override bool keysEqual(ulong[] a, ulong[] b) {
    return arrayEqual(a, b);
  }

  override void addValue(ulong[] layoutIndices) {
    VkDescriptorSetLayout[] descriptorSetLayouts = map!(i => dsLayoutCollection.get(i))(layoutIndices).array;

    VkPipelineLayoutCreateInfo layoutInfo = {
      setLayoutCount: descriptorSetLayouts.length.to!uint,
      pSetLayouts: descriptorSetLayouts.ptr
    };

    values.length++;
    enforceVk(vkCreatePipelineLayout(device.logicalDevice, &layoutInfo, null, &values[$-1]));
  }

  void cleanup() {
    each!(v => vkDestroyPipelineLayout(device.logicalDevice, v, null))(values);
  }
}
