# -- Build spirv-tools and inject path

mkdir ~/spirv-tools/build
cd ~/spirv-tools/build
cmake -G"Unix Makefiles" -DCMAKE_BUILD_TYPE=Release ..
make
cd -
export PATH="$PATH:$HOME/spirv-tools/build/tools"

# -- Build loader and validation layers

wd="$(pwd)"
cd ~/Vulkan-LoaderAndValidationLayers
./update_external_sources.sh
cmake -H. -Bbuild -DCMAKE_BUILD_TYPE=Debug
cd build
make
cd "${wd}"

export LD_LIBRARY_PATH="$HOME/Vulkan-LoaderAndValidationLayers/build/loaders:$LD_LIBRARY_PATH"
export VK_LAYER_PATH="$HOME/Vulkan-LoaderAndValidationLayers/build/layers"

# -- Run tests

dub test --compiler=${DC}
