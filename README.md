# Bynar - A controlled compute shader execution library

Still early in development.

This library provides a high level interface into Vulkan which allows you to describe the flow and execution of shader modules in sequence.

## Goals

- Provide an input size independent way of chaining modules together that abstracts vulkan resource management
- Provide a robust set of tools for specifying the control flow of an entire parallel application in relation to comput shaders
- Provide an extendable set of abstractions to allow programs using the library to specify the execution behavior of any linear compute shader

## Currently done

- Can specify exection with set of modules and sequence of stages
- Execution strategies calculate execution parameters given an input size

## TODO

- Execution strategies aware of element size
- Multiple input sets to one stage
- Control flow
- CPU stages (function hooks for stages via semaphores)

## Development

Interested on working with/on this library? Reach out to me personally and I can work with you.
