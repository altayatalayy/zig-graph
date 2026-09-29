#include "MyTestOutputGwImpl.hpp"

#include <cstdio>

void MyTestOutputGw::gatewayMain(gateway_inputs& inputs, gateway_outputs& outputs)
{
    inputs.readInput();

    if (inputs.filter()) {
        inputs.forward();
    }

    for (auto& sample : inputs.get().m_acccmd) {
        const auto& d = sample.get();
        std::fprintf(stderr, "[acccmd] received sample\n");
        (void)d;
    }

    for (auto& sample : inputs.get().m_torquereq) {
        const auto& d = sample.get();
        std::fprintf(stderr, "[torquereq] received sample\n");
        (void)d;
    }

    (void)outputs;
}