use rustler::{Env, ResourceArc, Term, Error, NifResult, Atom, Binary, OwnedBinary};
use nokhwa::Camera;
use nokhwa::utils::{CameraIndex, RequestedFormat, RequestedFormatType,  FrameFormat, CameraFormat};
use nokhwa::pixel_format::RgbFormat;
use std::sync::Mutex;
use std::io::Cursor;
use image::ImageFormat;

mod atoms {
    rustler::atoms! {
        ok,
        error,
    }
}

struct CameraResource {
    camera: Mutex<Camera>,
}

#[rustler::nif]
fn open_camera(index: u32, width: u32, height: u32, fps: u32) -> NifResult<ResourceArc<CameraResource>> {
    let index = CameraIndex::Index(index);
    let format = CameraFormat::new_from(
        width,
        height,
        FrameFormat::MJPEG,  
        fps
    );
    let requested = RequestedFormat::new::<RgbFormat>(RequestedFormatType::Closest(format));

    let mut camera = Camera::new(index, requested).map_err(|e| Error::Term(Box::new(format!("Failed to create camera: {}", e))))?;
    
    camera.open_stream().map_err(|e| Error::Term(Box::new(format!("Failed to open stream: {}", e))))?;

    Ok(ResourceArc::new(CameraResource {
        camera: Mutex::new(camera),
    }))
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_frame<'a>(env: Env<'a>, resource: ResourceArc<CameraResource>) -> NifResult<(Atom, Binary<'a>, u32, u32)> {
    let mut camera = resource.camera.lock().map_err(|_| Error::Term(Box::new("Failed to lock camera")))?;
    
    let frame = camera.frame().map_err(|e| Error::Term(Box::new(format!("Failed to read frame: {}", e))))?;
    
    let resolution = frame.resolution();
    let width = resolution.width();
    let height = resolution.height();

    let img_buffer: image::RgbImage = frame.decode_image::<RgbFormat>()
        .map_err(|e| Error::Term(Box::new(format!("Failed to decode image: {}", e))))?;

    let mut png_data = Cursor::new(Vec::new());
    
    img_buffer.write_to(&mut png_data, ImageFormat::Png)
        .map_err(|e| Error::Term(Box::new(format!("Failed to encode PNG: {}", e))))?;
    
    let bytes = png_data.into_inner();
    let mut binary = OwnedBinary::new(bytes.len()).ok_or(Error::Term(Box::new("Failed to allocate binary")))?;
    binary.as_mut_slice().copy_from_slice(&bytes);
    
    Ok((atoms::ok(), binary.release(env), width, height))
}
fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(CameraResource, env);
    true
}

rustler::init!("Elixir.SendSlam.Native.CameraProducer", load = load);
