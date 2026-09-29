from conan.tools.cmake import CMakeDeps
from conans import CMake, ConanFile
import os

class FocusDemoConan(ConanFile):
    name = "focus_demo"
    version = "1.0"
    license = "Proprietary"
    author = "Demo"
    description = "FOCUS Demo Application with Producer and Consumer components"
    settings = "os", "compiler", "build_type", "arch"
    generators = "cmake_find_package", "virtualenv", "virtualrunenv", "json"
    keep_imports = True
    exports_sources = "*"
    options = {
        "CODE_GENERATOR": ["yaaac2"],
        "MIDDLEWARE_TARGET": ["carma_0_22"],
    }
    default_options = {
        "CODE_GENERATOR": "yaaac2",
        "MIDDLEWARE_TARGET": "carma_0_22",
    }

    def build_requirements(self):
        self.build_requires("aos_build_tools/0.36.0@aos/sdk")

    def generate(self):
        if hasattr(self, "settings_build"):
            cmakedeps = CMakeDeps(self)
            cmakedeps.build_context_activated.append("aos_build_tools")
            cmakedeps.generate()

    def requirements(self):
        self.requires("aos_runtime_dev/0.36.0@aos/sdk")
        self.requires("aos_runtime_prod/0.36.0@aos/sdk")
        self.requires("eigen/3.4.0")
    
    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
    
    def package(self):
        self.copy("*", dst="bin", src="build_linux/bin", keep_path=False)
        self.copy("*.so*", dst="lib", src="build_linux/lib", keep_path=False)
