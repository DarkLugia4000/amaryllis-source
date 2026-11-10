-- Section: Feedback primitive | Elapsed-time PID with bounded integration.
-- Full PID with derivative on measurement, elapsed seconds and conditional
-- integration. Derivative on measurement avoids a kick when R/F changes TGT.
-- Output and integral are bounded; a saturated output cannot accumulate error
-- that would drive it farther into saturation. No peripheral or disk access.
local PID = {}
function PID.new(gains)
    return setmetatable({g=gains,i=0,d=0}, {__index=PID})
end
-- Summary: Clear integral and derivative state and seed the previous measurement.
function PID:reset(measurement)
    self.i,self.d,self.previous=0,0,measurement
end
-- Section: Feedback primitive | Elapsed-time PID with bounded integration.
-- Summary: Advance the PID terms using elapsed time, measured derivative and bounded integration.
function PID:step(target, measurement, dt, minimum, maximum)
    assert(dt > 0 and dt <= 3, "PID sample interval must be in (0,3] seconds")
    local g, error = self.g, target-measurement
    local rawD = self.previous and -(measurement-self.previous)/dt or 0
    local alpha = dt/(g.derivative_filter_seconds+dt)
    self.d = self.d + alpha*(rawD-self.d)
    self.previous=measurement
    local candidate = math.max(-g.integral_limit,math.min(g.integral_limit,self.i+error*dt))
    local output = g.kp*error+g.ki*candidate+g.kd*self.d
    -- Opposing error must be able to unwind a learned offset even when the
    -- proportional/derivative response reaches the opposite output limit.
    if self.i*error<0 or not ((output>maximum and error>0) or (output<minimum and error<0)) then self.i=candidate end
    output=g.kp*error+g.ki*self.i+g.kd*self.d
    return math.max(minimum,math.min(maximum,output)), output<minimum or output>maximum
end
return PID
