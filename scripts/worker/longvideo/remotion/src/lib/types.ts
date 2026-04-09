/** Input props for all long video compositions */
export interface LVInputProps {
  /** Array of segments with text, visual info, and timing */
  segments: Segment[];
  /** Paths to per-segment audio files */
  audioFiles: AudioFile[];
  /** Paths to per-segment scene images */
  imageFiles: ImageFile[];
  /** Path to the opening digital human video (optional) */
  openingVideoPath?: string;
  /** Video dimensions */
  width: number;
  height: number;
  /** Frames per second */
  fps: number;
  /** Total duration in frames */
  durationInFrames: number;
  /** Track-specific config */
  config: TrackRenderConfig;
}

export interface Segment {
  index: number;
  text: string;
  visualPrompt: string;
  durationHint: number;
  segmentType: "digital_human" | "static_visual";
  /** Actual duration in seconds from TTS audio */
  actualDuration: number;
  /** Start frame in the composition */
  startFrame: number;
  /** End frame in the composition */
  endFrame: number;
}

export interface AudioFile {
  index: number;
  path: string;
  duration: number;
}

export interface ImageFile {
  index: number;
  path: string;
}

export interface TrackRenderConfig {
  kenBurns: boolean;
  transition: "crossfade" | "cut" | "slide";
  transitionDuration: number;
  subtitleStyle: "bottom_center" | "top_center" | "none";
  introDuration: number;
  outroDuration: number;
}
