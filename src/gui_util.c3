module ksvisu;

import raylib5;
import std::math;

fn float clamp(float value, float min_val, float max_val)
{
    float lower_bound_result = math::max(value, min_val);
    return math::min(lower_bound_result, max_val);
}
