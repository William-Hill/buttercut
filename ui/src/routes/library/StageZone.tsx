import { forwardRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import type { VideoEntry } from "./types";

interface Props {
  video: VideoEntry | undefined;
  footageSummary: string;
}

const StageZone = forwardRef<HTMLVideoElement, Props>(function StageZone({ video, footageSummary }, ref) {
  const [errored, setErrored] = useState(false);

  if (!video) {
    return <div className="stage stage--empty"><p>No clip selected.</p></div>;
  }

  const src = convertFileSrc(video.path);

  return (
    <div className="stage">
      <div className="stage__player">
        {errored ? (
          <div className="stage__missing">
            <p>Can't find the video file.</p>
            <p className="stage__missing-path">Expected at: <code>{video.path}</code></p>
          </div>
        ) : (
          <video
            ref={ref}
            key={video.path}
            src={src}
            controls
            preload="metadata"
            onError={() => setErrored(true)}
          />
        )}
      </div>
      {footageSummary && <FootageSummary text={footageSummary} />}
    </div>
  );
});

function FootageSummary({ text }: { text: string }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className={`stage__summary ${expanded ? "stage__summary--expanded" : ""}`}>
      <p>{text}</p>
      <button className="stage__summary-toggle" onClick={() => setExpanded((v) => !v)}>
        {expanded ? "Show less" : "Show more"}
      </button>
    </div>
  );
}

export default StageZone;
