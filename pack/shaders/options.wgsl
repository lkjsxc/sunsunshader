// SPDX-License-Identifier: Apache-2.0
// Profile indices: Low 0, Medium 1, High 2, Ultra 3.
override quality: u32 = 1u;
override exposure: f32 = 1.0;
override haze: f32 = 1.0;

override shadows: bool = true;
override water_reflections: bool = true;
// Fixed normal-wave amplitude; the profiles control reflection work.
override water_waves: f32 = 1.0;

override clouds: bool = true;
override weather_detail: bool = true;

override bloom: f32 = 0.10;
override depth_of_field: bool = false;
override camera_motion_blur: bool = false;
override vignette: bool = false;
