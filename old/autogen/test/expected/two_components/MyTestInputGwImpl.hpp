#ifndef MYTESTINPUTGW_IMPL_HPP
#define MYTESTINPUTGW_IMPL_HPP

#include <cstdint>
#include <optional>
#include <vector>

class MyTestInputGw
{
public:
    struct StepData
    {
        std::uint64_t timestamp_ns;
        std::optional<VehicleSpeed> vehiclespeed;
        std::optional<TargetSpeed> targetspeed;
        std::optional<RoadGrade> roadgrade;
    };

    void gatewayMain(gateway_inputs& inputs, gateway_outputs& outputs);

private:
    std::vector<StepData> getTestSteps();
};

#endif