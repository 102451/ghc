{-# OPTIONS -fno-implicit-prelude -#include "PrelIOUtils.h" #-}

#undef DEBUG_DUMP

-- -----------------------------------------------------------------------------
-- $Id: PrelIO.hs,v 1.2 2001/11/08 17:02:41 simonmar Exp $
--
-- (c) The University of Glasgow, 1992-2001
--
-- Module PrelIO

-- This module defines all basic IO operations.
-- These are needed for the IO operations exported by Prelude,
-- but as it happens they also do everything required by library
-- module IO.

module PrelIO ( 
   putChar, putStr, putStrLn, print, getChar, getLine, getContents,
   interact, readFile, writeFile, appendFile, readLn, readIO, hReady,
   hWaitForInput, hGetChar, hGetLine, hGetContents, hPutChar, hPutStr,
   hPutStrLn, hPrint,
   commitBuffer',	-- hack, see below
   hGetcBuffered,	-- needed by ghc/compiler/utils/StringBuffer.lhs
 ) where

import PrelBase

import PrelPosix
import PrelMarshalUtils
import PrelStorable
import PrelCError
import PrelCString
import PrelCTypes
import PrelCTypesISO

import PrelIOBase
import PrelHandle	-- much of the real stuff is in here

import PrelMaybe
import PrelReal
import PrelNum
import PrelRead
import PrelShow
import PrelMaybe	( Maybe(..) )
import PrelPtr
import PrelList
import PrelException    ( ioError, catch, throw )
import PrelConc

-- -----------------------------------------------------------------------------
-- Standard IO

putChar         :: Char -> IO ()
putChar c       =  hPutChar stdout c

putStr          :: String -> IO ()
putStr s        =  hPutStr stdout s

putStrLn        :: String -> IO ()
putStrLn s      =  do putStr s
                      putChar '\n'

print           :: Show a => a -> IO ()
print x         =  putStrLn (show x)

getChar         :: IO Char
getChar         =  hGetChar stdin

getLine         :: IO String
getLine         =  hGetLine stdin

getContents     :: IO String
getContents     =  hGetContents stdin

interact        ::  (String -> String) -> IO ()
interact f      =   do s <- getContents
                       putStr (f s)

readFile        :: FilePath -> IO String
readFile name	=  openFile name ReadMode >>= hGetContents

writeFile       :: FilePath -> String -> IO ()
writeFile name str = do
    hdl <- openFile name WriteMode
    hPutStr hdl str
    hClose hdl

appendFile      :: FilePath -> String -> IO ()
appendFile name str = do
    hdl <- openFile name AppendMode
    hPutStr hdl str
    hClose hdl

readLn          :: Read a => IO a
readLn          =  do l <- getLine
                      r <- readIO l
                      return r

  -- raises an exception instead of an error
readIO          :: Read a => String -> IO a
readIO s        =  case (do { (x,t) <- reads s ;
			      ("","") <- lex t ;
                              return x }) of
#ifndef NEW_READS_REP
			[x]    -> return x
			[]     -> ioError (userError "Prelude.readIO: no parse")
			_      -> ioError (userError "Prelude.readIO: ambiguous parse")
#else
                        Just x -> return x
                        Nothing  -> ioError (userError "Prelude.readIO: no parse")
#endif

-- ---------------------------------------------------------------------------
-- Simple input operations

-- Computation "hReady hdl" indicates whether at least
-- one item is available for input from handle "hdl".

-- If hWaitForInput finds anything in the Handle's buffer, it
-- immediately returns.  If not, it tries to read from the underlying
-- OS handle. Notice that for buffered Handles connected to terminals
-- this means waiting until a complete line is available.

hReady :: Handle -> IO Bool
hReady h = hWaitForInput h 0

hWaitForInput :: Handle -> Int -> IO Bool
hWaitForInput h msecs = do
  wantReadableHandle "hReady" h $ \ handle_ -> do
  let ref = haBuffer handle_
  buf <- readIORef ref

  if not (bufferEmpty buf)
	then return True
	else do

  r <- throwErrnoIfMinus1Retry "hReady"
	  (inputReady (fromIntegral (haFD handle_)) (fromIntegral msecs))
  return (r /= 0)

foreign import "inputReady" unsafe
  inputReady :: CInt -> CInt -> IO CInt

-- ---------------------------------------------------------------------------
-- hGetChar

-- hGetChar reads the next character from a handle,
-- blocking until a character is available.

hGetChar :: Handle -> IO Char
hGetChar handle =
  wantReadableHandle "hGetChar" handle $ \handle_ -> do

  let fd = haFD handle_
      ref = haBuffer handle_

  buf <- readIORef ref
  if not (bufferEmpty buf)
	then hGetcBuffered fd ref buf
	else do

  -- buffer is empty.
  case haBufferMode handle_ of
    LineBuffering    -> do
	new_buf <- fillReadBuffer fd True buf
	hGetcBuffered fd ref new_buf
    BlockBuffering _ -> do
	new_buf <- fillReadBuffer fd False buf
	hGetcBuffered fd ref new_buf
    NoBuffering -> do
	-- make use of the minimal buffer we already have
	let raw = bufBuf buf
	r <- throwErrnoIfMinus1RetryMayBlock "hGetChar"
	        (read_off (fromIntegral fd) raw 0 1)
	        (threadWaitRead fd)
	if r == 0
	   then ioe_EOF
	   else do (c,_) <- readCharFromBuffer raw 0
		   return c

hGetcBuffered fd ref buf@Buffer{ bufBuf=b, bufRPtr=r, bufWPtr=w }
 = do (c,r) <- readCharFromBuffer b r
      let new_buf | r == w    = buf{ bufRPtr=0, bufWPtr=0 }
	          | otherwise = buf{ bufRPtr=r }
      writeIORef ref new_buf
      return c

-- ---------------------------------------------------------------------------
-- hGetLine

-- If EOF is reached before EOL is encountered, ignore the EOF and
-- return the partial line. Next attempt at calling hGetLine on the
-- handle will yield an EOF IO exception though.

-- ToDo: the unbuffered case is wrong: it doesn't lock the handle for
-- the duration.
hGetLine :: Handle -> IO String
hGetLine h = do
  m <- wantReadableHandle "hGetLine" h $ \ handle_ -> do
    	case haBufferMode handle_ of
    	   NoBuffering      -> return Nothing
    	   LineBuffering    -> do
    	      l <- hGetLineBuffered handle_
    	      return (Just l)
    	   BlockBuffering _ -> do 
    	      l <- hGetLineBuffered handle_
    	      return (Just l)
  case m of
	Nothing -> hGetLineUnBuffered h
	Just l  -> return l


hGetLineBuffered handle_ = do
  let ref = haBuffer handle_
  buf <- readIORef ref
  hGetLineBufferedLoop handle_ ref buf []


hGetLineBufferedLoop handle_ ref 
	buf@Buffer{ bufRPtr=r, bufWPtr=w, bufBuf=raw } xss =
  let 
	-- find the end-of-line character, if there is one
	loop raw r
	   | r == w = return (False, w)
	   | otherwise =  do
		(c,r') <- readCharFromBuffer raw r
		if c == '\n' 
		   then return (True, r) -- NB. not r': don't include the '\n'
		   else loop raw r'
  in do
  (eol, off) <- loop raw r

#ifdef DEBUG_DUMP
  puts ("hGetLineBufferedLoop: r=" ++ show r ++ ", w=" ++ show w ++ ", off=" ++ show off ++ "\n")
#endif

  xs <- unpack raw r off
  if eol
	then do if w == off + 1
		   then writeIORef ref buf{ bufRPtr=0, bufWPtr=0 }
		   else writeIORef ref buf{ bufRPtr = off + 1 }
	        return (concat (reverse (xs:xss)))
	else do
	     maybe_buf <- maybeFillReadBuffer (haFD handle_) True 
				buf{ bufWPtr=0, bufRPtr=0 }
	     case maybe_buf of
		-- Nothing indicates we caught an EOF, and we may have a
		-- partial line to return.
		Nothing -> let str = concat (reverse (xs:xss)) in
		     	   if not (null str)
			      then return str
			      else ioe_EOF
		Just new_buf -> 
		     hGetLineBufferedLoop handle_ ref new_buf (xs:xss)


maybeFillReadBuffer fd is_line buf
  = catch 
     (do buf <- fillReadBuffer fd is_line buf
	 return (Just buf)
     )
     (\e -> do if isEOFError e 
		  then return Nothing 
		  else throw e)


unpack :: RawBuffer -> Int -> Int -> IO [Char]
unpack buf r 0   = return ""
unpack buf (I# r) (I# len) = IO $ \s -> unpack [] (len -# 1#) s
   where
    unpack acc i s
     | i <# r  = (# s, acc #)
     | otherwise = 
          case readCharArray# buf i s of
	    (# s, ch #) -> unpack (C# ch : acc) (i -# 1#) s


hGetLineUnBuffered :: Handle -> IO String
hGetLineUnBuffered h = do
  c <- hGetChar h
  if c == '\n' then
     return ""
   else do
    l <- getRest
    return (c:l)
 where
  getRest = do
    c <- 
      catch 
        (hGetChar h)
        (\ err -> do
          if isEOFError err then
	     return '\n'
	   else
	     ioError err)
    if c == '\n' then
       return ""
     else do
       s <- getRest
       return (c:s)

-- -----------------------------------------------------------------------------
-- hGetContents

-- hGetContents returns the list of characters corresponding to the
-- unread portion of the channel or file managed by the handle, which
-- is made semi-closed.

-- hGetContents on a DuplexHandle only affects the read side: you can
-- carry on writing to it afterwards.

hGetContents :: Handle -> IO String
hGetContents handle = 
    withHandle "hGetContents" handle $ \handle_ ->
    case haType handle_ of 
      ClosedHandle 	   -> ioe_closedHandle
      SemiClosedHandle 	   -> ioe_closedHandle
      AppendHandle 	   -> ioe_notReadable
      WriteHandle 	   -> ioe_notReadable
      _ -> do xs <- lazyRead handle
	      return (handle_{ haType=SemiClosedHandle}, xs )

-- Note that someone may close the semi-closed handle (or change its
-- buffering), so each time these lazy read functions are pulled on,
-- they have to check whether the handle has indeed been closed.

lazyRead :: Handle -> IO String
lazyRead handle = 
   unsafeInterleaveIO $
	withHandle "lazyRead" handle $ \ handle_ -> do
	case haType handle_ of
	  ClosedHandle     -> return (handle_, "")
	  SemiClosedHandle -> lazyRead' handle handle_
	  _ -> ioException 
	 	  (IOError (Just handle) IllegalOperation "lazyRead"
			"illegal handle type" Nothing)

lazyRead' h handle_ = do
  let ref = haBuffer handle_
      fd  = haFD handle_

  -- even a NoBuffering handle can have a char in the buffer... 
  -- (see hLookAhead)
  buf <- readIORef ref
  if not (bufferEmpty buf)
	then lazyReadHaveBuffer h handle_ fd ref buf
	else do

  case haBufferMode handle_ of
     NoBuffering      -> do
	-- make use of the minimal buffer we already have
	let raw = bufBuf buf
	    fd  = haFD handle_
	r <- throwErrnoIfMinus1RetryMayBlock "lazyRead"
	        (read_off (fromIntegral fd) raw 0 1)
	        (threadWaitRead fd)
	if r == 0
	   then do handle_ <- hClose_help handle_ 
		   return (handle_, "")
	   else do (c,_) <- readCharFromBuffer raw 0
		   rest <- lazyRead h
		   return (handle_, c : rest)

     LineBuffering    -> lazyReadBuffered h handle_ fd ref buf
     BlockBuffering _ -> lazyReadBuffered h handle_ fd ref buf

-- we never want to block during the read, so we call fillReadBuffer with
-- is_line==True, which tells it to "just read what there is".
lazyReadBuffered h handle_ fd ref buf = do
   catch 
   	(do buf <- fillReadBuffer fd True{-is_line-} buf
	    lazyReadHaveBuffer h handle_ fd ref buf
     	)
	-- all I/O errors are discarded.  Additionally, we close the handle.
     	(\e -> do handle_ <- hClose_help handle_
		  return (handle_, "")
	)

lazyReadHaveBuffer h handle_ fd ref buf = do
   more <- lazyRead h
   writeIORef ref buf{ bufRPtr=0, bufWPtr=0 }
   s <- unpackAcc (bufBuf buf) (bufRPtr buf) (bufWPtr buf) more
   return (handle_, s)


unpackAcc :: RawBuffer -> Int -> Int -> [Char] -> IO [Char]
unpackAcc buf r 0 acc  = return ""
unpackAcc buf (I# r) (I# len) acc = IO $ \s -> unpack acc (len -# 1#) s
   where
    unpack acc i s
     | i <# r  = (# s, acc #)
     | otherwise = 
          case readCharArray# buf i s of
	    (# s, ch #) -> unpack (C# ch : acc) (i -# 1#) s

-- ---------------------------------------------------------------------------
-- hPutChar

-- `hPutChar hdl ch' writes the character `ch' to the file or channel
-- managed by `hdl'.  Characters may be buffered if buffering is
-- enabled for `hdl'.

hPutChar :: Handle -> Char -> IO ()
hPutChar handle c = 
    c `seq` do   -- must evaluate c before grabbing the handle lock
    wantWritableHandle "hPutChar" handle $ \ handle_  -> do
    let fd = haFD handle_
    case haBufferMode handle_ of
	LineBuffering    -> hPutcBuffered handle_ True  c
	BlockBuffering _ -> hPutcBuffered handle_ False c
	NoBuffering      ->
		withObject (castCharToCChar c) $ \buf ->
		throwErrnoIfMinus1RetryMayBlock_ "hPutChar"
		   (c_write (fromIntegral fd) buf 1)
		   (threadWaitWrite fd)


hPutcBuffered handle_ is_line c = do
  let ref = haBuffer handle_
  buf <- readIORef ref
  let w = bufWPtr buf
  w'  <- writeCharIntoBuffer (bufBuf buf) w c
  let new_buf = buf{ bufWPtr = w' }
  if bufferFull new_buf || is_line && c == '\n'
     then do 
  	flushed_buf <- flushWriteBuffer (haFD handle_) new_buf
  	writeIORef ref flushed_buf
     else do 
  	writeIORef ref new_buf


hPutChars :: Handle -> [Char] -> IO ()
hPutChars handle [] = return ()
hPutChars handle (c:cs) = hPutChar handle c >> hPutChars handle cs

-- ---------------------------------------------------------------------------
-- hPutStr

-- `hPutStr hdl s' writes the string `s' to the file or
-- hannel managed by `hdl', buffering the output if needs be.

-- We go to some trouble to avoid keeping the handle locked while we're
-- evaluating the string argument to hPutStr, in case doing so triggers another
-- I/O operation on the same handle which would lead to deadlock.  The classic
-- case is
--
--		putStr (trace "hello" "world")
--
-- so the basic scheme is this:
--
--	* copy the string into a fresh buffer,
--	* "commit" the buffer to the handle.
--
-- Committing may involve simply copying the contents of the new
-- buffer into the handle's buffer, flushing one or both buffers, or
-- maybe just swapping the buffers over (if the handle's buffer was
-- empty).  See commitBuffer below.

hPutStr :: Handle -> String -> IO ()
hPutStr handle str = do
    buffer_mode <- wantWritableHandle "hPutStr" handle 
			(\ handle_ -> do getSpareBuffer handle_)
    case buffer_mode of
       (NoBuffering, _) -> do
	    hPutChars handle str	-- v. slow, but we don't care
       (LineBuffering, buf) -> do
	    writeLines handle buf str
       (BlockBuffering _, buf) -> do
            writeBlocks handle buf str


getSpareBuffer :: Handle__ -> IO (BufferMode, Buffer)
getSpareBuffer Handle__{haBuffer=ref, 
			haBuffers=spare_ref,
			haBufferMode=mode}
 = do
   case mode of
     NoBuffering -> return (mode, error "no buffer!")
     _ -> do
          bufs <- readIORef spare_ref
	  buf  <- readIORef ref
	  case bufs of
 	    BufferListCons b rest -> do
		writeIORef spare_ref rest
		return ( mode, newEmptyBuffer b WriteBuffer (bufSize buf))
	    BufferListNil -> do
		new_buf <- allocateBuffer (bufSize buf) WriteBuffer
		return (mode, new_buf)


writeLines :: Handle -> Buffer -> String -> IO ()
writeLines hdl Buffer{ bufBuf=raw, bufSize=len } s =
  let
   shoveString :: Int -> [Char] -> IO ()
	-- check n == len first, to ensure that shoveString is strict in n.
   shoveString n cs | n == len = do
	new_buf <- commitBuffer hdl raw len n True{-needs flush-} False
	writeLines hdl new_buf cs
   shoveString n [] = do
	commitBuffer hdl raw len n False{-no flush-} True{-release-}
	return ()
   shoveString n (c:cs) = do
	n' <- writeCharIntoBuffer raw n c
	if (c == '\n') 
	   then do 
		new_buf <- commitBuffer hdl raw len n' True{-needs flush-} False
		writeLines hdl new_buf cs
	   else	
		shoveString n' cs
  in
  shoveString 0 s

writeBlocks :: Handle -> Buffer -> String -> IO ()
writeBlocks hdl Buffer{ bufBuf=raw, bufSize=len } s =
  let
   shoveString :: Int -> [Char] -> IO ()
	-- check n == len first, to ensure that shoveString is strict in n.
   shoveString n cs | n == len = do
	new_buf <- commitBuffer hdl raw len n True{-needs flush-} False
	writeBlocks hdl new_buf cs
   shoveString n [] = do
	commitBuffer hdl raw len n False{-no flush-} True{-release-}
	return ()
   shoveString n (c:cs) = do
	n' <- writeCharIntoBuffer raw n c
	shoveString n' cs
  in
  shoveString 0 s

-- -----------------------------------------------------------------------------
-- commitBuffer handle buf sz count flush release
-- 
-- Write the contents of the buffer 'buf' ('sz' bytes long, containing
-- 'count' bytes of data) to handle (handle must be block or line buffered).
-- 
-- Implementation:
-- 
--    for block/line buffering,
-- 	 1. If there isn't room in the handle buffer, flush the handle
-- 	    buffer.
-- 
-- 	 2. If the handle buffer is empty,
-- 		 if flush, 
-- 		     then write buf directly to the device.
-- 		     else swap the handle buffer with buf.
-- 
-- 	 3. If the handle buffer is non-empty, copy buf into the
-- 	    handle buffer.  Then, if flush != 0, flush
-- 	    the buffer.

commitBuffer
	:: Handle			-- handle to commit to
	-> RawBuffer -> Int		-- address and size (in bytes) of buffer
	-> Int				-- number of bytes of data in buffer
	-> Bool				-- True <=> flush the handle afterward
	-> Bool 			-- release the buffer?
	-> IO Buffer

commitBuffer hdl raw sz@(I# _) count@(I# _) flush release = do
  wantWritableHandle "commitAndReleaseBuffer" hdl $
     commitBuffer' hdl raw sz count flush release

-- Explicitly lambda-lift this function to subvert GHC's full laziness
-- optimisations, which otherwise tends to float out subexpressions
-- past the \handle, which is really a pessimisation in this case because
-- that lambda is a one-shot lambda.
--
-- Don't forget to export the function, to stop it being inlined too
-- (this appears to be better than NOINLINE, because the strictness
-- analyser still gets to worker-wrapper it).
--
-- This hack is a fairly big win for hPutStr performance.  --SDM 18/9/2001
--
commitBuffer' hdl raw sz@(I# _) count@(I# _) flush release
  handle_@Handle__{ haFD=fd, haBuffer=ref, haBuffers=spare_buf_ref } = do

#ifdef DEBUG_DUMP
      puts ("commitBuffer: sz=" ++ show sz ++ ", count=" ++ show count
	    ++ ", flush=" ++ show flush ++ ", release=" ++ show release ++"\n")
#endif

      old_buf@Buffer{ bufBuf=old_raw, bufRPtr=r, bufWPtr=w, bufSize=size }
	  <- readIORef ref

      buf_ret <-
        -- enough room in handle buffer?
	 if (not flush && (size - w > count))
		-- The > is to be sure that we never exactly fill
		-- up the buffer, which would require a flush.  So
		-- if copying the new data into the buffer would
		-- make the buffer full, we just flush the existing
		-- buffer and the new data immediately, rather than
		-- copying before flushing.

		-- not flushing, and there's enough room in the buffer:
		-- just copy the data in and update bufWPtr.
	    then do memcpy_off old_raw w raw (fromIntegral count)
		    writeIORef ref old_buf{ bufWPtr = w + count }
		    return (newEmptyBuffer raw WriteBuffer sz)

		-- else, we have to flush
	    else do flushed_buf <- flushWriteBuffer fd old_buf

		    let this_buf = 
			    Buffer{ bufBuf=raw, bufState=WriteBuffer, 
				    bufRPtr=0, bufWPtr=count, bufSize=sz }

			-- if:  (a) we don't have to flush, and
			--      (b) size(new buffer) == size(old buffer), and
			--      (c) new buffer is not full,
			-- we can just just swap them over...
		    if (not flush && sz == size && count /= sz)
			then do 
			  writeIORef ref this_buf
			  return flushed_buf			     

			-- otherwise, we have to flush the new data too,
			-- and start with a fresh buffer
			else do 
			  flushWriteBuffer fd this_buf
			  writeIORef ref flushed_buf
			    -- if the sizes were different, then allocate
			    -- a new buffer of the correct size.
			  if sz == size
			     then return (newEmptyBuffer raw WriteBuffer sz)
			     else allocateBuffer size WriteBuffer

      -- release the buffer if necessary
      case buf_ret of
        Buffer{ bufSize=buf_ret_sz, bufBuf=buf_ret_raw } -> do
          if release && buf_ret_sz == size
	    then do
	      spare_bufs <- readIORef spare_buf_ref
	      writeIORef spare_buf_ref 
		(BufferListCons buf_ret_raw spare_bufs)
	      return buf_ret
	    else
	      return buf_ret


foreign import "prel_PrelIO_memcpy" unsafe 
   memcpy_off :: RawBuffer -> Int -> RawBuffer -> CSize -> IO (Ptr ())

-- ---------------------------------------------------------------------------
-- hPutStrLn

-- Derived action `hPutStrLn hdl str' writes the string `str' to
-- the handle `hdl', adding a newline at the end.

hPutStrLn :: Handle -> String -> IO ()
hPutStrLn hndl str = do
 hPutStr  hndl str
 hPutChar hndl '\n'

-- ---------------------------------------------------------------------------
-- hPrint

-- Computation `hPrint hdl t' writes the string representation of `t'
-- given by the `shows' function to the file or channel managed by `hdl'.

hPrint :: Show a => Handle -> a -> IO ()
hPrint hdl = hPutStrLn hdl . show
