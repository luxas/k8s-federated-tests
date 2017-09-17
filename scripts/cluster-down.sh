#!/bin/bash

# This script tears down a kubeadm-created cluster

set -x

kubeadm reset
