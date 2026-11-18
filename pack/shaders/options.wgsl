// SPDX-License-Identifier: Apache-2.0
// Profile indices: Low 0, Medium 1, High 2.
override quality: u32 = 1u;
override exposure: f32 = 1.0;
override haze: f32 = 1.0;
override local_haze: bool = true;

override shadows: bool = true;
override water_reflections: bool = true;
// Surface-wave amplitude; the profiles separately control reflection work.
override water_waves: f32 = 1.0;

override clouds: bool = true;
override weather_detail: bool = true;

override bloom: f32 = 0.10;
override depth_of_field: bool = false;
override camera_motion_blur: bool = false;
override vignette: bool = false;

override contact_shading: bool = true;
override wind: bool = true;
override light_shafts: bool = true;
