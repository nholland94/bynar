import std.algorithm.iteration;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.process;
import std.random;
import std.range;
import std.stdio;
import std.typecons;

import erupted;

import common;
import device;
import execution_strategies;
import execution_pipeline;
import input_rel_exp;
import test_utils;

uint[] runTest(VkInstance instance, ExecutionModule[] modules, ExecutionStage[] stages, uint[] data) {
  Device device = new Device(instance);

  // ExecutionPipeline p;
  // auto r = benchmark!(() => p = new ExecutionPipeline(device, modules, stages, data.length * uint.sizeof))(1);
  // writeln("preparation: ", r[0].to!Duration);

  ExecutionPipeline p = new ExecutionPipeline(device, modules, stages, data.length * uint.sizeof);

  // uint[] output;
  // r = benchmark!(() => output = p.execute(data))(1);
  // writeln("execution: ", r[0].to!Duration);
  uint[] output = p.execute(data);

  p.cleanup();
  device.cleanup();

  return output;
}

// /// test sequential copy
// unittest {
//   InputRelExp identityExp = { bytecode: castFrom!(InputRelOp[]).to!(int[])([InputRelOp.Input]).ptr };
//   ExecutionModule[] modules = [
//     loadExecutionModule("copy.spv")
//   ];
//   ExecutionStage[] stages = [
//     { 0, "f", new Sequential(identityExp) }
//   ];
// 
//   TestInstance ti = prepareTest();
// 
//   void runAndCheck(uint[] data) {
//     uint[] output = runTest(ti.instance, modules, stages, data);
//     foreach(i; iota(output.length)) {
//       assert(output[i] == data[i]);
//     }
//   }
// 
//   int testCount = 20;
// 
//   writeln("=============");
//   writefln("Copy %d times", testCount);
//   writeln("=============");
//   foreach(i; iota(testCount)) {
//     int len = uniform(0, 5_000);
//     writefln("-- copying %d words", len);
//     runAndCheck(randomData(len, 10_000));
//   }
// 
//   cleanupTest(ti);
// }
// 
// /// test reduce
// unittest {
//   ExecutionModule[] modules = [
//     loadExecutionModule("reduce_scalar.spv")
//   ];
//   ExecutionStage[] stages = [
//     { 0, "f", new Reductive() }
//   ];
// 
//   TestInstance ti = prepareTest();
// 
//   void runAndCheck(uint[] data) {
//     uint[] output = runTest(ti.instance, modules, stages, data);
//     // uint sum;
//     // auto r = benchmark!(() => sum = fold!"a+b"(data))(1);
//     // writeln("cpu: ", r[0].to!Duration);
//     uint sum = data.fold!"a+b"();
//     writeln(output[0], " = ", sum);
//     assert(output.length == 1);
//     assert(output[0] == sum);
//   }
// 
//   int smallTestCount = 20;
//   int largeTestCount = 5;
// 
//   writeln("=======================");
//   writefln("Reduce %d small vectors", smallTestCount);
//   writeln("=======================");
//   foreach(i; iota(smallTestCount)) {
//     // int len = uniform(10, 5_000);
//     int len = uniform(800, 900);
//     writefln("-- summing %d words", len);
//     runAndCheck(randomData(len, 10_000));
//   }
// 
//   writeln("=======================");
//   writefln("Reduce %d large vectors", largeTestCount);
//   writeln("=======================");
//   foreach(i; iota(largeTestCount)) {
//     int len = uniform(1_000_000, 10_000_000);
//     writefln("-- summing %d words", len);
//     runAndCheck(randomData(len, 10_000));
//   }
// 
//   cleanupTest(ti);
// }

/// test reduce span
unittest {
  ExecutionModule[] modules = [
    loadExecutionModule("reduce_tree.spv")
  ];
  ExecutionStage[] stages = [
    { 0, "f", new ReductiveSpan(6) }
  ];

  TestInstance ti = prepareTest();

  void runAndCheck(uint[] data) {
    uint[] output = runTest(ti.instance, modules, stages, data);
    // uint sum;
    // auto r = benchmark!(() => sum = fold!"a+b"(data))(1);
    // writeln("cpu: ", r[0].to!Duration);
    uint sum = data.fold!"a+b"();
    writeln(output[0], " = ", sum);
    assert(output.length == 1);
    assert(output[0] == sum);
  }

  int smallTestCount = 100;
  int largeTestCount = 20;

  writeln("=======================");
  writefln("Reduce %d small vectors", smallTestCount);
  writeln("=======================");
  foreach(i; iota(smallTestCount)) {
    int len = uniform(10, 100);
    writefln("-- summing %d words", len);
    runAndCheck(randomData(len, 10_000));
  }

  writeln("=======================");
  writefln("Reduce %d large vectors", largeTestCount);
  writeln("=======================");
  foreach(i; iota(largeTestCount)) {
    int len = uniform(1_000_000, 10_000_000);
    writefln("-- summing %d words", len);
    runAndCheck(randomData(len, 10_000));
  }

  cleanupTest(ti);
}

/// linear pipelines
unittest {
  TestInstance ti = prepareTest();

  void runAndCheck(ExecutionModule[] modules, ExecutionStage[] stages, uint[] data, uint[] expectation) {
    uint[] output = runTest(ti.instance, modules, stages, data);
    assert(output.length == expectation.length);
    foreach(i; iota(output.length)) {
      assert(output[i] == expectation[i]);
    }
  }

  writeln("=======================");
  writeln("Copy and reduce");
  writeln("=======================");

  {
    uint[] data = randomData(1_024, 5_000);
    uint sum = fold!"a+b"(data);

    InputRelExp identityExp = { bytecode: castFrom!(InputRelOp[]).to!(int[])([InputRelOp.Input]).ptr };

    ExecutionModule[] modules = [
      loadExecutionModule("copy.spv"),
      loadExecutionModule("reduce_scalar.spv")
    ];
    ExecutionStage[] stages = [
      { 0, "f", new Sequential(identityExp) },
      { 1, "f", new Reductive() }
    ];

    runAndCheck(modules, stages, data, [sum]);
  }

  cleanupTest(ti);
}
