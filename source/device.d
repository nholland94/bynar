import std.algorithm;
import std.conv;
import std.exception;
import std.typecons;

import erupted;

import common;

Tuple!(VkPhysicalDevice, uint) findSuitablePhysicalDevice(VkPhysicalDevice[] devices) {
  uint largestQueueCount = 0;

  foreach(device; devices) {
    uint queueFamilyCount;
    vkGetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, null);

    VkQueueFamilyProperties[] queueFamilyProps;
    queueFamilyProps.length = queueFamilyCount;

    vkGetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, queueFamilyProps.ptr);
    foreach(i, props; queueFamilyProps) {
      if(props.queueFlags & VK_QUEUE_COMPUTE_BIT) {
        return tuple!(VkPhysicalDevice, uint)(device, i.to!uint);
      }
    }
  }

  throw new Exception("Failed to find suitable physical device");
}

class Device {
  VkPhysicalDevice physicalDevice;
  VkDevice logicalDevice;
  VkQueue queue;

  uint queueFamilyIndex;
  
  private Nullable!VkPhysicalDeviceProperties properties;
  private Nullable!VkPhysicalDeviceMemoryProperties memoryProperties;

  this(VkInstance instance) {
    uint physicalDeviceCount;
    enforceVk(vkEnumeratePhysicalDevices(instance, &physicalDeviceCount, null));
    enforce(physicalDeviceCount > 0, "no devices found");

    VkPhysicalDevice[] physicalDevices;
    physicalDevices.length = physicalDeviceCount;
    enforceVk(vkEnumeratePhysicalDevices(instance, &physicalDeviceCount, physicalDevices.ptr));

    destruct!(physicalDevice, queueFamilyIndex) = findSuitablePhysicalDevice(physicalDevices);

    const float queuePriority = 1;

    const VkDeviceQueueCreateInfo[] queueInfos = [
      {
        queueFamilyIndex: queueFamilyIndex.to!uint,
        queueCount: 1,
        pQueuePriorities: &queuePriority
      }
    ];

    const VkDeviceCreateInfo deviceInfo = {
      queueCreateInfoCount: queueInfos.length.to!uint,
      pQueueCreateInfos: queueInfos.ptr
    };

    enforceVk(vkCreateDevice(physicalDevice, &deviceInfo, null, &logicalDevice));
    vkGetDeviceQueue(logicalDevice, queueFamilyIndex, 0, &queue);
  }

  VkPhysicalDeviceProperties getProperties() {
    if(properties.isNull) {
      VkPhysicalDeviceProperties x;
      vkGetPhysicalDeviceProperties(physicalDevice, &x);
      properties = x;
    }

    return properties;
  }

  VkPhysicalDeviceMemoryProperties getMemoryProperties() {
    if(memoryProperties.isNull) {
      VkPhysicalDeviceMemoryProperties x;
      vkGetPhysicalDeviceMemoryProperties(physicalDevice, &x);
      memoryProperties = x;
    }

    return memoryProperties;
  }

  VkPhysicalDeviceLimits getLimits() {
    return getProperties().limits;
  }

  void cleanup() {
    vkDestroyDevice(logicalDevice, null);
  }
}
