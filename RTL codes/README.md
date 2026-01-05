## RTL Overview

This repository contains the final synthesizable RTL for a reconfigurable CNN accelerator datapath. The design consists of a Partial Feature Map Producer (PFPM) and two dense layer modules.

The PFPM module implements the core computation of the convolutional layer. It performs valid cross-correlation between the input feature map and a set of kernels to generate partial feature maps. Partial feature maps across all input depths are accumulated along with bias to form the final feature map. The PFPM module is fully pipelined and can either be reused using an external controller or re-instantiated to increase parallelism, providing flexibility in CNN design.

Two dense layer modules are provided. The first dense layer applies weighted summation followed by Leaky ReLU activation, while the final dense layer performs argmax to generate a one-hot encoded classification output. The dense layers incorporate batch processing, allowing the batch size to be adjusted to trade off between latency and area.

All modules use signed Q1.15 fixed-point arithmetic to reduce hardware complexity while maintaining sufficient numerical precision. The RTL is fully pipelined, parameterizable, and written entirely in synthesizable Verilog.

