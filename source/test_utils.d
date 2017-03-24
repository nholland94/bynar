import std.conv;
import std.file;
import std.process;
import std.random;
import std.range;
import std.stdio;

import erupted;

import common;
import execution_pipeline;

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

uint[] randomData(int length, int maxValue) {
  uint[] data;
  data.length = length;

  foreach(i; iota(length)) {
    data[i] = uniform(0, maxValue);
  }

  return data;
}

ExecutionModule loadExecutionModule(string name) {
  string spvFilename = "shaders/" ~ name;
  string sourceFilename = spvFilename[0..$-3] ~ "spirv";

  if(!exists(spvFilename)) {
    if(!exists(sourceFilename)) throw new Exception("Shader source filename does not exist");
    auto spirvAs = execute(["spirv-as", "-o", spvFilename, sourceFilename]);
    if(spirvAs.status != 0) {
      writeln(spirvAs.output);
      if(exists(spvFilename)) remove(spvFilename);
      throw new Exception("Failed to compile source file");
    }

    auto spirvVal = execute(["spirv-val", spvFilename]);
    if(spirvVal.status != 0) {
      writeln(spirvVal.output);
      remove(spvFilename);
      throw new Exception("Failed to validate shader");
    }
  }

  uint[] code = castFrom!(void[]).to!(uint[])(read(spvFilename));
  return ExecutionModule(name, code);
}

struct TestInstance {
  VkInstance instance;
  VkDebugReportCallbackEXT debugCallback;
}

TestInstance prepareTest() {
  TestInstance i;
  DerelictErupted.load();

  i.instance = initalizeInstance();

  loadInstanceLevelFunctions(i.instance);
  loadDeviceLevelFunctions(i.instance);

  i.debugCallback = setupDebugReportCallback(i.instance);

  return i;
}

void cleanupTest(TestInstance i) {
  vkDestroyDebugReportCallbackEXT(i.instance, i.debugCallback, null);
  vkDestroyInstance(i.instance, null);
}
