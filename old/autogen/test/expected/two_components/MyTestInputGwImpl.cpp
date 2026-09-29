#include "MyTestInputGwImpl.hpp"

#include <cstdio>
#include <utility>
#include <vector>

std::vector<MyTestInputGw::StepData> MyTestInputGw::getTestSteps()
{
    return {};
}

void MyTestInputGw::gatewayMain(gateway_inputs& inputs, gateway_outputs& outputs)
{
    const auto steps = getTestSteps();

    for (const auto& step : steps) {
        std::fprintf(
            stderr,
            "[step] timestamp_ns=%llu\n",
            static_cast<unsigned long long>(step.timestamp_ns)
        );

        if (step.vehiclespeed.has_value()) {
            auto sample = outputs.m_vehiclespeed.allocate();
            *sample = step.vehiclespeed.value();
            outputs.m_vehiclespeed.send(std::move(sample));
        }

        if (step.targetspeed.has_value()) {
            auto sample = outputs.m_targetspeed.allocate();
            *sample = step.targetspeed.value();
            outputs.m_targetspeed.send(std::move(sample));
        }

        if (step.roadgrade.has_value()) {
            auto sample = outputs.m_roadgrade.allocate();
            *sample = step.roadgrade.value();
            outputs.m_roadgrade.send(std::move(sample));
        }

    }

    (void)inputs;
}
