export interface VideoEntry {
  filename: string;
  path: string;
  duration_seconds: number;
  has_audio_transcript: boolean;
  has_visual_transcript: boolean;
  has_summary: boolean;
}

export interface LibraryDetail {
  name: string;
  footage_summary: string;
  video_paths_root: string;
  videos: VideoEntry[];
}

export interface AudioWord {
  word: string;
  start: number;
  end: number;
}

export interface AudioSegment {
  start: number;
  end: number;
  text: string;
  words?: AudioWord[];
}

export interface VisualSegment {
  start: number;
  end: number;
  visual: string;
  text?: string;
  b_roll?: boolean;
}

export interface ClipTranscripts {
  audio: { language?: string; segments: AudioSegment[] } | null;
  visual: { language?: string; segments: VisualSegment[] } | null;
  summary: string | null;
}
