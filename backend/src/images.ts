import { APIError } from './db.js';

export const maxImageBytes = 2 * 1024 * 1024;
export const imagesSchema = {
  type: 'array', maxItems: 4,
  items: { type: 'string', maxLength: Math.ceil(maxImageBytes / 3) * 4 + 23, pattern: '^data:image/(png|jpeg);base64,[A-Za-z0-9+/]+={0,2}$' },
};

export function validateImages(value: unknown): asserts value is string[] | undefined {
  if (value === undefined) return;
  if (!Array.isArray(value) || value.length > 4) throw new APIError(400, 'Attach at most 4 PNG or JPEG images');
  for (const image of value) {
    if (typeof image !== 'string' || image.length > Math.ceil(maxImageBytes / 3) * 4 + 23)
      throw new APIError(400, 'Each image must be a PNG or JPEG data URL of at most 2 MiB');
    const match = /^data:image\/(png|jpeg);base64,([A-Za-z0-9+/]+={0,2})$/.exec(image);
    if (!match) throw new APIError(400, 'Images must be inline PNG or JPEG base64 data URLs');
    const data = Buffer.from(match[2]!, 'base64');
    if (data.length > maxImageBytes || data.toString('base64') !== match[2])
      throw new APIError(400, 'Image data must be strict base64 of at most 2 MiB');
    const valid = match[1] === 'png'
      ? data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
      : data.length >= 3 && data[0] === 255 && data[1] === 216 && data[2] === 255;
    if (!valid) throw new APIError(400, 'Image data does not match its PNG or JPEG type');
  }
}

export function validatePrompt(prompt: unknown, images: string[]) {
  if (typeof prompt !== 'string' || (!prompt.trim() && !images.length))
    throw new APIError(400, 'Enter a message or attach an image');
}
