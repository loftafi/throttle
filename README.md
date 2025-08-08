## Throttle

This project provides a rudimentary way to throttle any type of request or
action. It could be used to throttle sign in requests based on a user's
email address, or the origin IP address.

This code is for my personal use, and works for my purposes. There is no
guarantee that it will be suitable and reliable for your purposes. The
code is released under the MIT licence, you are free to use it, but
strongly urged to fully test that the code functions correctly for your
use cases.

## How to use

Limit calls to an API to 5 per second, or lockout for one minute
    
```zig
pub const Throttle = @import("throttle").Throttle;
pub const us_per_s = std.time.us_per_s;

var counter = Throttle.init(us_per_s * 1, 5, us_per_s * 60);
if (counter.isThrottled()) {
    std.log.warn("Try again later");
}
```
    
Limit signin attempts on an email address to 5 per minute, or
lockout for 5 minutes.
    
```zig
var counter = StringThrottleCache.init(std.time.us_per_min * 1, 5, std.time.us_per_m * 5);
const email = "john@example.com";
if (counter.isThrottled(&email)) {
    std.log.warn("Try again later");
}
```
    
Limit  signin attemps from an IP address to 5 attempts per
minute, or lockout for 2 minutes.

```zig
var counter = ThrottleCache.init(i128, std.time.us_per_min * 1, 5, std.time.us_per_min * 2);
if (counter.isThrottled(ip_address) {
    std.log.warn("Try again later");
}
```
    
