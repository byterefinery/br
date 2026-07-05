---
name: label
description: Logical time marker. Use when you need a named point of reference in the conversation that other skills or messages can anchor to. Like a label in C/C++ — a place you can jump back to.
metadata:
  tags:
    - meta
---

# label

## Overview

Creates a named marker at the current point in the conversation. Other skills, messages, or instructions can reference it by name to anchor context, restore state, or branch logic. Labels are resolved in order — nearest matching label wins. They carry no data, only named position.

## Usage

### Activation

When invoked without a label name, output `label skill activated`.

### Definition of Label

Define a label using `LABEL_NAME`. Skill outputs exactly `label: LABEL_NAME`.
