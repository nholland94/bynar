# -- Build spirv-tools and inject path

mkdir ~/spirv-tools/build
cd ~/spirv-tools/build
cmake -G"Unix Makefiles" -DCMAKE_BUILD_TYPE=Release ..
make
cd -
export PATH="$PATH:$HOME/spirv-tools/build/tools"

# -- Run tests

dub test --compiler=${DC}
