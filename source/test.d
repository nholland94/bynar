import std.algorithm.iteration;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.random;
import std.range;
import std.stdio;
import std.typecons;

import erupted;

import common;
import constructors;
import int_rel_exp;
import execution;

extern(C) uint debugReportCallback(
    VkDebugReportFlagsEXT flags,
    VkDebugReportObjectTypeEXT objectType,
    ulong object,
    size_t location,
    int32_t messageCode,
    const(char)* pLayerPrefix,
    const(char)* pMessage,
    void* pUserData) nothrow @nogc {
  fputs("    %%%% ", core.stdc.stdio.stderr);
  fputs(pMessage, core.stdc.stdio.stderr);
  putc('\n', core.stdc.stdio.stderr);
  return VK_FALSE;
}

VkDebugReportCallbackEXT setupDebugReportCallback(VkInstance instance) {
  VkDebugReportCallbackCreateInfoEXT callbackInfo = {
    flags: VK_DEBUG_REPORT_ERROR_BIT_EXT | VK_DEBUG_REPORT_WARNING_BIT_EXT,
    pfnCallback: &debugReportCallback
  };

  VkDebugReportCallbackEXT callback;
  enforceVk(vkCreateDebugReportCallbackEXT(instance, &callbackInfo, null, &callback));
  return callback;
}

VkInstance initalizeInstance() {
  immutable(char)*[] layerNames = [
    "VK_LAYER_LUNARG_standard_validation"
  ];

  immutable(char)*[] extensionNames = [
    VK_EXT_DEBUG_REPORT_EXTENSION_NAME.ptr
  ];

  VkApplicationInfo applicationInfo = {
    pApplicationName: "Test",
    apiVersion: VK_MAKE_VERSION(1, 0, 2)
  };
  
  VkInstanceCreateInfo instanceInfo = {
    pApplicationInfo: &applicationInfo,
    enabledLayerCount: layerNames.length.to!uint,
    ppEnabledLayerNames: layerNames.ptr,
    enabledExtensionCount: extensionNames.length.to!uint,
    ppEnabledExtensionNames: extensionNames.ptr
  };

  VkInstance instance;
  enforceVk(vkCreateInstance(&instanceInfo, null, &instance));

  return instance;
}

Tuple!(VkPhysicalDevice, "physicalDevice", VkDevice, "logicalDevice", VkQueue, "queue", uint, "queueFamilyIndex")
initializeDevice(VkInstance instance) {
  uint deviceCount;
  enforceVk(vkEnumeratePhysicalDevices(instance, &deviceCount, null));
  enforce(deviceCount > 0, "no devices found");

  auto physicalDevices = uninitializedArray!(VkPhysicalDevice[])(deviceCount);
  enforceVk(vkEnumeratePhysicalDevices(instance, &deviceCount, physicalDevices.ptr));

  auto physicalDeviceQueueFamilyProps = uninitializedArray!(VkQueueFamilyProperties[][])(deviceCount);

  Nullable!ulong physicalDeviceIndex = Nullable!ulong.init;
  Nullable!ulong familyIndex = Nullable!ulong.init;
  uint largestQueueCount = 0;

  foreach(i, physicalDevice; physicalDevices) {
    uint queueFamilyCount;
    vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, null);

    auto queueFamilyProps = uninitializedArray!(VkQueueFamilyProperties[])(queueFamilyCount);
    vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, queueFamilyProps.ptr);

    foreach(j, props; queueFamilyProps) {
      if(props.queueFlags & VK_QUEUE_COMPUTE_BIT) {
        physicalDeviceIndex = i;
        familyIndex = i;
        largestQueueCount = props.queueCount;
      }
    }
  }

  enforce(!(physicalDeviceIndex.isNull || familyIndex.isNull), "no compute queue found");

  VkPhysicalDevice physicalDevice = physicalDevices[physicalDeviceIndex];
  uint queueFamilyIndex = familyIndex.get.to!uint;

  const float queuePriority = 1;

  const VkDeviceQueueCreateInfo[] queueInfos = [
    {
      queueFamilyIndex: queueFamilyIndex,
      queueCount: 1,
      pQueuePriorities: &queuePriority
    }
  ];

  const VkDeviceCreateInfo deviceInfo = {
    queueCreateInfoCount: queueInfos.length.to!uint,
    pQueueCreateInfos: queueInfos.ptr
  };

  VkDevice device;
  enforceVk(vkCreateDevice(physicalDevice, &deviceInfo, null, &device));

  VkQueue queue;
  vkGetDeviceQueue(device, queueFamilyIndex, 0, &queue);

  return tuple!("physicalDevice", "logicalDevice", "queue", "queueFamilyIndex")(physicalDevice, device, queue, queueFamilyIndex);
}

uint[] randomData(int length, int maxValue) {
  uint[] data;
  data.length = length;

  foreach(i; iota(length)) {
    data[i] = uniform(0, maxValue);
  }

  return data;
}

VkInstance instance;
VkDebugReportCallbackEXT debugCallback;

void prepareTest() {
  DerelictErupted.load();

  instance = initalizeInstance();

  loadInstanceLevelFunctions(instance);
  loadDeviceLevelFunctions(instance);

  debugCallback = setupDebugReportCallback(instance);
}

void cleanupTest() {
  vkDestroyDebugReportCallbackEXT(instance, debugCallback, null);
  vkDestroyInstance(instance, null);
}

uint[] runTest(PipelineConstructorInterface[] constructors, uint[] data) {
  auto deviceResult = initializeDevice(instance);
  VkPhysicalDevice physicalDevice = deviceResult.physicalDevice;
  VkDevice device = deviceResult.logicalDevice;
  VkQueue queue = deviceResult.queue;
  uint queueFamilyIndex = deviceResult.queueFamilyIndex;

  VkPhysicalDeviceMemoryProperties memoryProperties;
  vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memoryProperties);

  VkPhysicalDeviceProperties properties;
  vkGetPhysicalDeviceProperties(physicalDevice, &properties);

  uint[] output = executeConstructors!uint(memoryProperties, properties.limits, device, queue, queueFamilyIndex, constructors, data);

  vkDestroyDevice(device, null);

  return output;
}

/// test sequential copy
unittest {
  IntRelExp identityExp = { bytecode: castFrom!(IntRelOp[]).to!(int[])([IntRelOp.Input]).ptr };
  PipelineConstructorInterface[] constructors = [
    new SequentialPC(identityExp, "copy.spv", "f")
  ];

  void runAndCheck(uint[] data) {
    uint[] output = runTest(constructors, data);
    foreach(i; iota(output.length)) {
      assert(output[i] == data[i]);
    }
  }

  int testCount = 20;

  prepareTest();

  writeln("=============");
  writefln("Copy %d times", testCount);
  writeln("=============");
  foreach(i; iota(testCount)) {
    int len = uniform(0, 5000);
    writefln("-- copying %d words", len);
    runAndCheck(randomData(len, 10000));
  }

  cleanupTest();
}

// test reduce
unittest {
  PipelineConstructorInterface[] constructors = [
    new ReductivePC("reduce.spv", "f")
  ];

  void runAndCheck(uint[] data) {
    uint[] output = runTest(constructors, data);
    uint sum = fold!"a+b"(data);
    assert(output.length == 1);
    writefln("    ** %d == %d **", output[0], sum);
    assert(output[0] == sum);
  }

  int smallTestCount = 20;
  int largeTestCount = 5;

  prepareTest();

  writeln("=======================");
  writefln("Reduce %d small vectors", smallTestCount);
  writeln("=======================");
  foreach(i; iota(smallTestCount)) {
    int len = uniform(10, 5000);
    writefln("-- summing %d words", len);
    runAndCheck(randomData(len, 10000));
  }

  writeln("=======================");
  writefln("Reduce %d large vectors", largeTestCount);
  writeln("=======================");
  foreach(i; iota(largeTestCount)) {
    int len = uniform(100000, 10000000);
    writefln("-- summing %d words", len);
    runAndCheck(randomData(len, 10000));
  }

  cleanupTest();
}
