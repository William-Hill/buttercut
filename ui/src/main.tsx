import React from "react";
import ReactDOM from "react-dom/client";
import "./styles/theme.css";
import Projects from "./routes/projects";
import Library from "./routes/library";

function pickRoute() {
  const hash = window.location.hash || "";
  const match = hash.match(/^#\/library\/(.+)$/);
  if (match) {
    return <Library name={decodeURIComponent(match[1])} />;
  }
  return <Projects />;
}

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>{pickRoute()}</React.StrictMode>,
);
