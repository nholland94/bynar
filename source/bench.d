import std.algorithm.iteration;
import std.conv;
import std.datetime;
import std.stdio;

import erupted;
import progress;

import device;
import execution_pipeline;
import execution_strategies;
import input_rel_exp;
import test_utils;

TestInstance ti;
Device d;

static const prepCount = 10_000;
static const execCount = 10_000;

struct BenchmarkResult {
  string name;
  TickDuration[] preparation;
  TickDuration[] execution;
}

alias Benchmark = BenchmarkResult function();

TickDuration benchmarkPreparation(ExecutionModule[] modules, ExecutionStage[] stages, uint[] data) {
  ExecutionPipeline p;
  TickDuration[] r = benchmark!(() => p = new ExecutionPipeline(d, modules, stages, data.length * uint.sizeof))(1);
  p.cleanup();

  return r[0];
}

TickDuration benchmarkExecution(ExecutionModule[] modules, ExecutionStage[] stages, uint[] data) {
  ExecutionPipeline p = new ExecutionPipeline(d, modules, stages, data.length * uint.sizeof);
  uint[] output;
  TickDuration[] r = benchmark!(() => output = p.execute(data))(1);
  p.cleanup();

  return r[0];
}

BenchmarkResult benchSequential() {
  InputRelExp identityExp = { bytecode: castFrom!(InputRelOp[]).to!(int[])([InputRelOp.Input]).ptr };
  ExecutionModule[] modules = [
    loadExecutionModule("copy.spv")
  ];
  ExecutionStage[] stages = [
    { 0, "f", new Sequential(identityExp) }
  ];

  Progress p;
  p = new Progress(prepCount);
  p.title = "Sequential Preparation";

  TickDuration[] prep;
  prep.length = prepCount;

  foreach(ref d; prep) {
    d = benchmarkPreparation(modules, stages, randomData(10_000, 100_000));
    p.next();
  }

  writeln();

  p = new Progress(execCount);
  p.title = "Sequential Execution";

  TickDuration[] exec;
  exec.length = execCount;

  foreach(ref d; exec) {
    d = benchmarkExecution(modules, stages, randomData(10_000, 100_000));
    p.next();
  }

  writeln();

  return BenchmarkResult("sequential", prep, exec);
}

BenchmarkResult benchReductiveSmall() {
  ExecutionModule[] modules = [
    loadExecutionModule("reduce_scalar.spv")
  ];
  ExecutionStage[] stages = [
    { 0, "f", new Reductive() }
  ];

  Progress p;
  p = new Progress(prepCount);
  p.title = "Reductive Preparation";

  TickDuration[] prep;
  prep.length = prepCount;

  foreach(ref d; prep) {
    d = benchmarkPreparation(modules, stages, randomData(10_000, 100_000));
    p.next();
  }

  writeln();

  p = new Progress(execCount);
  p.title = "Reductive Execution";

  TickDuration[] exec;
  exec.length = execCount;

  foreach(ref d; exec) {
    d = benchmarkExecution(modules, stages, randomData(10_000, 100_000));
    p.next();
  }

  writeln();

  return BenchmarkResult("small reductive", prep, exec);
}

BenchmarkResult benchReductiveLarge() {
  ExecutionModule[] modules = [
    loadExecutionModule("reduce_scalar.spv")
  ];
  ExecutionStage[] stages = [
    { 0, "f", new Reductive() }
  ];

  Progress p;
  p = new Progress(500);
  p.title = "Reductive Preparation";

  TickDuration[] prep;
  prep.length = 500;

  foreach(ref d; prep) {
    d = benchmarkPreparation(modules, stages, randomData(10_000_000, 100_000));
    p.next();
  }

  writeln();

  p = new Progress(500);
  p.title = "Reductive Execution";

  TickDuration[] exec;
  exec.length = 500;

  foreach(ref d; exec) {
    d = benchmarkExecution(modules, stages, randomData(10_000_000, 100_000));
    p.next();
  }

  writeln();

  return BenchmarkResult("large reductive", prep, exec);
}

BenchmarkResult benchReductiveSpanSmall() {
  ExecutionModule[] modules = [
    loadExecutionModule("reduce_tree.spv")
  ];
  ExecutionStage[] stages = [
    { 0, "f", new ReductiveSpan(6) }
  ];

  Progress p;
  p = new Progress(prepCount);
  p.title = "Reductive Preparation";

  TickDuration[] prep;
  prep.length = prepCount;

  foreach(ref d; prep) {
    d = benchmarkPreparation(modules, stages, randomData(10_000, 100_000));
    p.next();
  }

  writeln();

  p = new Progress(execCount);
  p.title = "Reductive Execution";

  TickDuration[] exec;
  exec.length = execCount;

  foreach(ref d; exec) {
    d = benchmarkExecution(modules, stages, randomData(10_000, 100_000));
    p.next();
  }

  writeln();

  return BenchmarkResult("small reductive span", prep, exec);
}

BenchmarkResult benchReductiveSpanLarge() {
  ExecutionModule[] modules = [
    loadExecutionModule("reduce_tree.spv")
  ];
  ExecutionStage[] stages = [
    { 0, "f", new ReductiveSpan(128) }
  ];

  Progress p;
  p = new Progress(500);
  p.title = "Reductive Preparation";

  TickDuration[] prep;
  prep.length = 500;

  foreach(ref d; prep) {
    d = benchmarkPreparation(modules, stages, randomData(10_000_000, 100_000));
    p.next();
  }

  writeln();

  p = new Progress(500);
  p.title = "Reductive Execution";

  TickDuration[] exec;
  exec.length = 500;

  foreach(ref d; exec) {
    d = benchmarkExecution(modules, stages, randomData(10_000_000, 100_000));
    p.next();
  }

  writeln();

  return BenchmarkResult("large reductive span", prep, exec);
}

Benchmark[] benchmarks = [
  // &benchSequential,
  // &benchReductiveSmall,
  // &benchReductiveLarge,
  // &benchReductiveSpanSmall,
  &benchReductiveSpanLarge
];

int main() {
  ti = prepareTest();
  d = new Device(ti.instance);

  foreach(benchmark; benchmarks) {
    BenchmarkResult r = benchmark();
    writeln("=====================");
    writeln(r.name);
    writeln("=====================");

    TickDuration prepSum = r.preparation.fold!"a+b"();
    writefln("preparation: %s ::: %s / %s", (prepSum / r.preparation.length).to!Duration, prepSum.to!Duration, r.preparation.length);

    TickDuration execSum = r.execution.fold!"a+b"();
    writefln("execution: %s ::: %s / %s", (execSum / r.execution.length).to!Duration, execSum.to!Duration, r.execution.length);
  }

  d.cleanup();
  cleanupTest(ti);

  return 0;
}
