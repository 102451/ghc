import Foreign
import Monad

newtype Ptr a = Ptr Addr
unPtr (Ptr x) = x

type CInt  = Int32
type CSize = Word32

foreign export dynamic 
   mkComparator :: (Ptr Int -> Ptr Int -> IO CInt) 
		-> IO (Ptr (Ptr Int -> Ptr Int -> IO CInt))

foreign import 
   qsort :: Addr -> CSize -> CSize -> Ptr (Ptr Int -> Ptr Int -> IO CInt) 
	 -> IO ()

compareInts :: Ptr Int -> Ptr Int -> IO CInt
compareInts a1 a2 = do
   i1 <- peek (unPtr a1)
   i2 <- peek (unPtr a2)
   return (fromIntegral (i1 - i2 :: Int))

main :: IO ()
main = do
   let values = [ 12, 56, 90, 34, 78 ] :: [Int]
       n      = length values
   buf <- mallocElems (head values) n
   zipWithM_ (pokeElemOff buf) [ 0 .. ] values
   c <- mkComparator compareInts
   qsort buf (fromIntegral n) (fromIntegral (sizeOf (head values))) c
   mapM (peekElemOff buf) [ 0 .. n-1 ] >>= (print :: [Int] -> IO ())
