import React from "react";
import ReactDOM from "react-dom/client";
import "./styles/theme.css";
import Projects from "./routes/projects";
import Library from "./routes/library";
import NewProject from "./routes/new-project";

function pickRoute() {
  const hash = window.location.hash || "";
  const lib = hash.match(/^#\/library\/(.+)$/);
  if (lib) {
    try {
      return <Library name={decodeURIComponent(lib[1])} />;
    } catch {
      return <Projects />;
    }
  }
  if (hash === "#/new-project") {
    return <NewProject />;
  }
  return <Projects />;
}

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>{pickRoute()}</React.StrictMode>,
);
