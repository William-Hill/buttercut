import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type StageName = "transcribe" | "analyze" | "summarize";

export type JobEvent =
  | { method: "job_started"; params: { job_id: string; library: string; video_count: number; ts: string } }
  | { method: "file_started"; params: { job_id: string; video: string; stage: StageName; ts: string } }
  | {
      method: "file_progress";
      params: { job_id: string; video: string; stage: StageName; message?: string; percent?: number; ts: string };
    }
  | {
      method: "artifact_ready";
      params: { job_id: string; video: string; stage: StageName; artifact_path: string; ts: string };
    }
  | {
      method: "file_failed";
      params: { job_id: string; video: string; stage: StageName; error_kind: string; message: string; ts: string };
    }
  | { method: "file_done"; params: { job_id: string; video: string; stage: StageName; ts: string } }
  | {
      method: "job_done";
      params: { job_id: string; succeeded_count: number; failed_count: number; ts: string };
    }
  | {
      method: "job_canceled";
      params: { job_id: string; succeeded_count: number; failed_count: number; ts: string };
    };

export async function listenJobEvents(jobId: string, handler: (event: JobEvent) => void): Promise<UnlistenFn> {
  return listen<JobEvent>(`sidecar-event:${jobId}`, (e) => handler(e.payload));
}

/** Paths returned with `roughcut_job_done` (all absolute). */
export type RoughcutArtifactPaths = {
  yaml_path: string;
  xml_path: string;
  recipe_path: string;
  apply_path: string;
};

export type RoughcutClip = { source_file: string; in_point: string; out_point: string };

export type RoughcutJobEvent =
  | { method: "roughcut_job_started"; params: { job_id: string; library: string; ts?: string } }
  | { method: "roughcut_phase"; params: { job_id: string; phase: string; message?: string; ts?: string } }
  | {
      method: "roughcut_job_done";
      params: {
        job_id: string;
        library: string;
        yaml_path: string;
        xml_path: string;
        recipe_path: string;
        apply_path: string;
        clips: RoughcutClip[];
        ts?: string;
      };
    }
  | { method: "roughcut_job_failed"; params: { job_id: string; message: string; ts?: string } };

export async function listenRoughcutJobEvents(
  jobId: string,
  handler: (event: RoughcutJobEvent) => void,
): Promise<UnlistenFn> {
  return listen<RoughcutJobEvent>(`sidecar-event:${jobId}`, (e) => handler(e.payload));
}
