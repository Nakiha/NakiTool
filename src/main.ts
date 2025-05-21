import { createApp } from 'vue'
import App from './App.vue'

import './style.css'

import './demos/ipc'
// If you want use Node.js, the`nodeIntegration` needs to be enabled in the Main process.
// import './demos/node'

import { provideFluentDesignSystem, fluentCard, fluentButton } from '@fluentui/web-components';

provideFluentDesignSystem().register(fluentCard(), fluentButton());

createApp(App)
  .mount('#app')
  .$nextTick(() => {
    postMessage({ payload: 'removeLoading' }, '*')
  })
