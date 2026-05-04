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

export interface AcceptedVideo {
  path: string;
  duration_seconds: number;
  size_bytes: number;
}

export interface RejectedVideo {
  path: string;
  reason: "not_found" | "not_video" | "zero_duration";
}

export interface InspectResult {
  accepted: AcceptedVideo[];
  rejected: RejectedVideo[];
}

export async function inspectVideoPaths(paths: string[]): Promise<InspectResult> {
  return invoke<InspectResult>("inspect_video_paths", { paths });
}

export async function hasApiKey(): Promise<{ configured: boolean }> {
  return invoke<{ configured: boolean }>("has_api_key");
}

export async function setApiKey(key: string): Promise<{ ok: true }> {
  return invoke<{ ok: true }>("set_api_key", { key });
}

export interface CreateLibraryArgs {
  name: string;
  language: string;
  language_code: string;
  refinement: boolean;
  videos: AcceptedVideo[];
}

export async function createLibrary(args: CreateLibraryArgs): Promise<{ name: string }> {
  const { name, language, language_code, refinement, videos } = args;
  // Tauri maps Rust snake_case params to camelCase invoke keys.
  return invoke<{ name: string }>("create_library", {
    name,
    language,
    languageCode: language_code,
    refinement,
    videos,
  });
}

export async function startAnalysis(library: string): Promise<{ job_id: string }> {
  return invoke<{ job_id: string }>("start_analysis", { library });
}

export async function cancelJob(jobId: string): Promise<void> {
  await invoke("cancel_job", { jobId });
}

export async function openNewProjectWindow(): Promise<void> {
  await invoke("open_new_project_window");
}
