import ClipCard from "./ClipCard";
import type { VideoEntry } from "./types";

interface Props {
  library: string;
  videos: VideoEntry[];
  selected: string;
  onSelect: (filename: string) => void;
}

export default function ClipGrid({ library, videos, selected, onSelect }: Props) {
  return (
    <div className="clip-grid" role="listbox" aria-label="clips">
      {videos.map((v) => (
        <ClipCard
          key={v.filename}
          library={library}
          video={v}
          selected={v.filename === selected}
          onSelect={() => onSelect(v.filename)}
        />
      ))}
    </div>
  );
}
