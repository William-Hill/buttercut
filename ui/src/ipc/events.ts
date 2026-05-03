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
