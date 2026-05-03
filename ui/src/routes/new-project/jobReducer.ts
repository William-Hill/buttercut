import type { JobEvent, StageName } from "../../ipc/events";

export type StageState = "idle" | "queued" | "in_progress" | "done" | "failed";

export interface ClipState {
  video: string;
  stages: Record<StageName, StageState>;
  failure?: { stage: StageName; message: string; error_kind: string };
  artifacts: Partial<Record<StageName, string>>;
}

export interface JobState {
  job_id: string | null;
  videos: Record<string, ClipState>;
  totals: { done: number; failed: number; total: number };
  status: "running" | "canceling" | "canceled" | "complete";
}

export const initialJobState: JobState = {
  job_id: null,
  videos: {},
  totals: { done: 0, failed: 0, total: 0 },
  status: "running",
};

export type JobReducerAction = JobEvent | { method: "_internal_canceling" };

export function jobReducer(state: JobState, evt: JobReducerAction): JobState {
  switch (evt.method) {
    case "job_started":
      return {
        ...state,
        job_id: evt.params.job_id,
        totals: { ...state.totals, total: evt.params.video_count },
      };
    case "file_started":
      return updateClip(state, evt.params.video, (c) => ({
        ...c,
        stages: { ...c.stages, [evt.params.stage]: "in_progress" },
      }));
    case "file_done":
      return updateClip(state, evt.params.video, (c) => ({
        ...c,
        stages: { ...c.stages, [evt.params.stage]: "done" },
      }));
    case "artifact_ready":
      return updateClip(state, evt.params.video, (c) => ({
        ...c,
        artifacts: { ...c.artifacts, [evt.params.stage]: evt.params.artifact_path },
      }));
    case "file_failed":
      return updateClip(state, evt.params.video, (c) => ({
        ...c,
        stages: { ...c.stages, [evt.params.stage]: "failed" },
        failure: {
          stage: evt.params.stage,
          message: evt.params.message,
          error_kind: evt.params.error_kind,
        },
      }));
    case "job_done":
      return {
        ...state,
        status: "complete",
        totals: {
          ...state.totals,
          done: evt.params.succeeded_count,
          failed: evt.params.failed_count,
        },
      };
    case "job_canceled":
      return {
        ...state,
        status: "canceled",
        totals: {
          ...state.totals,
          done: evt.params.succeeded_count,
          failed: evt.params.failed_count,
        },
      };
    case "_internal_canceling":
      return { ...state, status: "canceling" };
    case "file_progress":
      return state;
  }
}

function updateClip(state: JobState, video: string, fn: (c: ClipState) => ClipState): JobState {
  const existing = state.videos[video] ?? {
    video,
    stages: { transcribe: "idle", analyze: "idle", summarize: "idle" },
    artifacts: {},
  };
  return { ...state, videos: { ...state.videos, [video]: fn(existing) } };
}
