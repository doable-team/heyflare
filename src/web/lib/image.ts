/**
 * Day photos are stored as bytes in D1, which is not an object store — so the browser does the
 * resizing before anything is uploaded. A wall-calendar photo never needs to be a 12-megapixel
 * original, and a 4MB upload would blow past D1's row ceiling anyway.
 */
export const MAX_COVER_EDGE = 1800;
export const MAX_COVER_BYTES = 1_400_000;

export interface PreparedImage {
  blob: Blob;
  width: number;
  height: number;
  type: string;
}

/**
 * Downscale to `MAX_COVER_EDGE` on the long side and re-encode, stepping the quality down until it
 * fits. Animated GIFs are passed through untouched when small enough — re-encoding one through a
 * canvas would freeze it on its first frame.
 */
export async function prepareCover(file: File): Promise<PreparedImage> {
  if (!/^image\//i.test(file.type)) throw new Error("That file isn't an image.");
  if (file.type === "image/gif" && file.size <= MAX_COVER_BYTES) {
    const size = await imageSize(file);
    return { blob: file, width: size.width, height: size.height, type: file.type };
  }

  const bitmap = await decode(file);
  const scale = Math.min(1, MAX_COVER_EDGE / Math.max(bitmap.width, bitmap.height));
  const width = Math.max(1, Math.round(bitmap.width * scale));
  const height = Math.max(1, Math.round(bitmap.height * scale));

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Couldn't read that image.");
  ctx.drawImage(bitmap as CanvasImageSource, 0, 0, width, height);
  if ("close" in bitmap && typeof bitmap.close === "function") bitmap.close();

  // Keep transparency when the source had it; otherwise JPEG is far smaller for a photo.
  const wantsAlpha = /png|webp|avif/i.test(file.type) && (await hasAlpha(ctx, width, height));
  const type = wantsAlpha ? "image/png" : "image/jpeg";
  for (const quality of [0.82, 0.72, 0.62, 0.5]) {
    const blob = await toBlob(canvas, type, quality);
    if (blob && (blob.size <= MAX_COVER_BYTES || type === "image/png")) return { blob, width, height, type: blob.type || type };
    if (blob && quality === 0.5) return { blob, width, height, type: blob.type || type };
  }
  throw new Error("Couldn't compress that image.");
}

function toBlob(canvas: HTMLCanvasElement, type: string, quality: number): Promise<Blob | null> {
  return new Promise((resolve) => canvas.toBlob(resolve, type, quality));
}

async function decode(file: File): Promise<ImageBitmap | HTMLImageElement> {
  if (typeof createImageBitmap === "function") {
    try {
      return await createImageBitmap(file);
    } catch {
      /* Safari can refuse some sources; fall through to an <img>. */
    }
  }
  return loadImage(file);
}

function loadImage(file: File): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Couldn't read that image."));
    };
    img.src = url;
  });
}

async function imageSize(file: File): Promise<{ width: number; height: number }> {
  const img = await loadImage(file);
  return { width: img.naturalWidth, height: img.naturalHeight };
}

/** Sample the alpha channel on a coarse grid — enough to notice a cut-out, cheap on a big canvas. */
async function hasAlpha(ctx: CanvasRenderingContext2D, width: number, height: number): Promise<boolean> {
  try {
    const step = Math.max(1, Math.floor(Math.min(width, height) / 40));
    for (let y = 0; y < height; y += step) {
      const row = ctx.getImageData(0, y, width, 1).data;
      for (let x = 3; x < row.length; x += 4 * step) if (row[x] < 250) return true;
    }
  } catch {
    /* A tainted canvas can't be read; assume opaque. */
  }
  return false;
}
