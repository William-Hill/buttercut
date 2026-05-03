import type { AcceptedVideo, RejectedVideo } from "../../ipc/sidecar";

export type StepId = "footage" | "name" | "language" | "refinement" | "confirm";

export interface SetupState {
  step: StepId;
  accepted: AcceptedVideo[];
  rejected: RejectedVideo[];
  name: string;
  language: { name: string; code: string };
  refinement: boolean;
  collisionWith: string | null;
}

export const initialSetup: SetupState = {
  step: "footage",
  accepted: [],
  rejected: [],
  name: "",
  language: { name: "English", code: "en" },
  refinement: true,
  collisionWith: null,
};

export type SetupAction =
  | { type: "add_files"; accepted: AcceptedVideo[]; rejected: RejectedVideo[] }
  | { type: "remove_file"; path: string }
  | { type: "set_name"; value: string }
  | { type: "set_collision"; value: string | null }
  | { type: "set_language"; name: string; code: string }
  | { type: "set_refinement"; value: boolean }
  | { type: "go_step"; step: StepId };

export function setupReducer(state: SetupState, action: SetupAction): SetupState {
  switch (action.type) {
    case "add_files": {
      const existing = new Set(state.accepted.map((v) => v.path));
      const merged = [...state.accepted, ...action.accepted.filter((v) => !existing.has(v.path))];
      return { ...state, accepted: merged, rejected: [...state.rejected, ...action.rejected] };
    }
    case "remove_file":
      return { ...state, accepted: state.accepted.filter((v) => v.path !== action.path) };
    case "set_name":
      return { ...state, name: action.value };
    case "set_collision":
      if (state.collisionWith === action.value) return state;
      return { ...state, collisionWith: action.value };
    case "set_language":
      return { ...state, language: { name: action.name, code: action.code } };
    case "set_refinement":
      return { ...state, refinement: action.value };
    case "go_step":
      return { ...state, step: action.step };
  }
}

export function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9-]/g, "")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}
