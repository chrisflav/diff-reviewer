import { createContext, type MutableRefObject } from "react";

/**
 * Whether the page on show holds edits not yet saved. A page sets it; signing out reads it, since
 * signing out leaves every page at once.
 */
export const UnsavedContext = createContext<MutableRefObject<boolean>>({ current: false });