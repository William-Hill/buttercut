import { invoke } from "@tauri-apps/api/core";

export interface LibrarySummary {
  name: string;
  video_count: number;
  last_touched_at: string; // ISO8601 UTC
}

export async function listLibraries(): Promise<LibrarySummary[]> {
  return invoke<LibrarySummary[]>("list_libraries");
}

export async function openLibraryWindow(name: string): Promise<void> {
  await invoke("open_library_window", { name });
}
