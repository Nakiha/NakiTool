declare global {
  interface Window {
    api: {
      getFilePath1: (file: File) => string;
      // 你可以在这里添加更多方法类型
    };
  }
}
export {};