import { invoke } from "@tauri-apps/api/core";
import type { ClipTranscripts, LibraryDetail } from "../routes/library/types";

export interface LibrarySummary {
  name: string;
  video_count: number;
  last_touched_at: string;
}

export async function listLibraries(): Promise<LibrarySummary[]> {
  return invoke<LibrarySummary[]>("list_libraries");
}

export async function openLibraryWindow(name: string): Promise<void> {
  await invoke("open_library_window", { name });
}

export async function getLibrary(name: string): Promise<LibraryDetail> {
  return invoke<LibraryDetail>("get_library", { name });
}

export async function getClipTranscripts(library: string, video: string): Promise<ClipTranscripts> {
  return invoke<ClipTranscripts>("get_clip_transcripts", { library, video });
}

export async function getOrGenerateThumbnail(library: string, video: string): Promise<{ path: string }> {
  return invoke<{ path: string }>("get_or_generate_thumbnail", { library, video });
}

export async function allowVideoPaths(root: string): Promise<void> {
  await invoke("allow_video_paths", { root });
}
