// The browser entry (CONTRACT.md, "Browser"): the assistant-ui adapter registers the thread foreign
// component on import, so it comes first; then the compiled `Viewer.UI.App` is mounted over the
// fetch-backed service.
import '../../../leanreact/adapters/assistant-ui/index.mjs';
import * as React from 'react';
import { createRoot } from 'react-dom/client';
import { mountElement, ctor } from '../../../leanreact/engine/adapters/leanjs-react.mjs';
import * as program from './generated/viewer.mjs';
import { createService } from './client.mjs';

createRoot(document.getElementById('root')).render(React.createElement(React.StrictMode, null,
  mountElement(program['Viewer.UI.App'], ctor('Viewer.UI.AppProps.mk', [createService(program)]))));
