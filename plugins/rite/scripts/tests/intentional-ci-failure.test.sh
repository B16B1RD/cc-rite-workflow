#!/bin/bash
if [ "$(uname -s)" = Darwin ]; then
  echo 'Intentional macOS script-suite failure: verify background exit blocks CI'
  exit 17
fi
